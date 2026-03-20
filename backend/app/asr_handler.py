import json
import logging
import asyncio
from typing import Optional

import dashscope
from dashscope.audio.asr import Recognition, RecognitionCallback, RecognitionResult
from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect, WebSocketState

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
        msg_type = "final" if is_end else "partial"
        logger.info("[ASR %s] sentence_id=%d text=%s", msg_type, self._sentence_id, text)
        self._enqueue({
            "type": msg_type,
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
        self._audio_frame_count = 0
        self._audio_byte_count = 0

    async def start(self):
        loop = asyncio.get_running_loop()
        self._callback = ASRSessionCallback(loop, self._send_queue)
        self._recognition = Recognition(
            model=ASR_MODEL,
            format=ASR_FORMAT,
            sample_rate=ASR_SAMPLE_RATE,
            callback=self._callback,
        )
        logger.info("ASR session starting... model=%s format=%s sample_rate=%d",
                     ASR_MODEL, ASR_FORMAT, ASR_SAMPLE_RATE)
        await loop.run_in_executor(None, self._recognition.start)
        self._started = True
        logger.info("ASR session started")

    def send_audio(self, audio_data: bytes):
        if self._recognition and self._started:
            self._audio_frame_count += 1
            self._audio_byte_count += len(audio_data)
            if self._audio_frame_count % 50 == 1:
                logger.info("[Audio] frame #%d, this=%d bytes, total=%d bytes",
                            self._audio_frame_count, len(audio_data), self._audio_byte_count)
            self._recognition.send_audio_frame(audio_data)

    async def stop(self):
        if self._recognition and self._started:
            logger.info("[Audio] 总计发送 %d 帧, %d 字节",
                        self._audio_frame_count, self._audio_byte_count)
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
    logger.info("客户端 WebSocket 已连接")
    session = ASRSession()
    client_disconnected = False

    async def send_results():
        """持续从队列中读取 ASR 结果并推送给客户端。"""
        nonlocal client_disconnected
        try:
            while True:
                msg = await session.message_queue.get()
                if client_disconnected or ws.client_state != WebSocketState.CONNECTED:
                    logger.info("[Send] 客户端已断开，丢弃消息: %s", msg.get("type"))
                    if msg.get("type") == "asr_complete":
                        break
                    continue
                logger.info("[Send] 推送消息: type=%s text=%s", msg.get("type"), msg.get("text", "")[:50])
                await ws.send_json(msg)
                if msg.get("type") == "asr_complete":
                    break
        except (WebSocketDisconnect, RuntimeError):
            logger.info("[Send] 客户端断开连接，停止发送")
            client_disconnected = True

    sender_task = None
    try:
        await session.start()
        sender_task = asyncio.create_task(send_results())

        while True:
            data = await ws.receive()
            if data.get("type") == "websocket.disconnect":
                logger.info("客户端主动断开连接")
                client_disconnected = True
                break
            if "bytes" in data:
                session.send_audio(data["bytes"])
            elif "text" in data:
                text_data = data["text"]
                logger.info("[Recv] 收到文本消息: %s", text_data[:200])
                msg = json.loads(text_data)
                if msg.get("action") == "stop":
                    logger.info("收到停止指令")
                    break
                if msg.get("action") == "execute_command":
                    command_text = msg.get("text", "")
                    logger.info("[Command] 执行指令: %s", command_text)
                    await ws.send_json({
                        "type": "command_status",
                        "status": "thinking",
                        "content": f"收到指令: {command_text}",
                    })
                    await ws.send_json({
                        "type": "command_result",
                        "status": "result",
                        "content": f"指令处理完成: {command_text}",
                    })
    except WebSocketDisconnect:
        logger.info("客户端断开连接 (WebSocketDisconnect)")
        client_disconnected = True
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
        logger.info("WebSocket 会话清理完成")
