import json
import logging
import asyncio
from typing import Optional

import dashscope
from dashscope.audio.asr import Recognition, RecognitionCallback, RecognitionResult
from fastapi import WebSocket

from app.config import (
    DASHSCOPE_API_KEY,
    DASHSCOPE_WS_URL,
    ASR_MODEL,
    ASR_SAMPLE_RATE,
    ASR_FORMAT,
)

logger = logging.getLogger(__name__)

dashscope.api_key = DASHSCOPE_API_KEY
dashscope.base_websocket_api_url = DASHSCOPE_WS_URL


class ASRSessionCallback(RecognitionCallback):
    """每个 WebSocket 会话对应一个 ASR 回调实例，
    将识别结果通过事件循环推送给客户端。"""

    def __init__(self, loop: asyncio.AbstractEventLoop, send_queue: asyncio.Queue):
        self._loop = loop
        self._queue = send_queue
        self._sentence_id = 0

    def _enqueue(self, msg: dict):
        self._loop.call_soon_threadsafe(self._queue.put_nowait, msg)

    def on_complete(self) -> None:
        logger.info("ASR recognition completed")
        self._enqueue({"type": "asr_complete"})

    def on_error(self, result: RecognitionResult) -> None:
        logger.error("ASR error: %s", result.message)
        self._enqueue({
            "type": "error",
            "text": f"ASR error: {result.message}",
        })

    def on_event(self, result: RecognitionResult) -> None:
        sentence = result.get_sentence()
        if "text" not in sentence:
            return
        text = sentence["text"]
        is_end = RecognitionResult.is_sentence_end(sentence)
        if is_end:
            self._sentence_id += 1
        self._enqueue({
            "type": "final" if is_end else "partial",
            "text": text,
            "sentence_id": self._sentence_id,
        })


class ASRSession:
    """管理单个客户端的 ASR 会话生命周期。"""

    def __init__(self):
        self._recognition: Optional[Recognition] = None
        self._send_queue: asyncio.Queue = asyncio.Queue()
        self._callback: Optional[ASRSessionCallback] = None
        self._started = False

    async def start(self):
        loop = asyncio.get_running_loop()
        self._callback = ASRSessionCallback(loop, self._send_queue)
        self._recognition = Recognition(
            model=ASR_MODEL,
            format=ASR_FORMAT,
            sample_rate=ASR_SAMPLE_RATE,
            callback=self._callback,
        )
        # start() 会在内部启动与 DashScope 的 WebSocket 连接（阻塞调用）
        await loop.run_in_executor(None, self._recognition.start)
        self._started = True
        logger.info("ASR session started")

    def send_audio(self, audio_data: bytes):
        if self._recognition and self._started:
            self._recognition.send_audio_frame(audio_data)

    async def stop(self):
        if self._recognition and self._started:
            loop = asyncio.get_running_loop()
            await loop.run_in_executor(None, self._recognition.stop)
            self._started = False
            logger.info("ASR session stopped")

    @property
    def message_queue(self) -> asyncio.Queue:
        return self._send_queue


async def handle_asr_websocket(ws: WebSocket):
    """处理来自客户端的 WebSocket 连接：
    - 接收二进制音频帧，转发给 DashScope ASR
    - 将识别结果实时推送给客户端
    """
    await ws.accept()
    session = ASRSession()

    async def send_results():
        """持续从队列中读取 ASR 结果并推送给客户端。"""
        try:
            while True:
                msg = await session.message_queue.get()
                await ws.send_json(msg)
                if msg.get("type") == "asr_complete":
                    break
        except Exception:
            logger.exception("发送结果时出错")

    sender_task = None
    try:
        await session.start()
        sender_task = asyncio.create_task(send_results())

        while True:
            data = await ws.receive()
            if data.get("type") == "websocket.disconnect":
                break
            if "bytes" in data:
                session.send_audio(data["bytes"])
            elif "text" in data:
                msg = json.loads(data["text"])
                if msg.get("action") == "stop":
                    break
                if msg.get("action") == "execute_command":
                    # 将指令文本存入队列，由后续模块处理
                    command_text = msg.get("text", "")
                    await ws.send_json({
                        "type": "command_status",
                        "status": "thinking",
                        "content": f"收到指令: {command_text}",
                    })
                    # TODO: 接入 AI 模型处理指令
                    await ws.send_json({
                        "type": "command_result",
                        "status": "result",
                        "content": f"指令处理完成: {command_text}",
                    })
    except Exception:
        logger.exception("WebSocket 会话异常")
    finally:
        await session.stop()
        if sender_task and not sender_task.done():
            sender_task.cancel()
            try:
                await sender_task
            except asyncio.CancelledError:
                pass
