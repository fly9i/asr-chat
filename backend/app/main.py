import logging
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, WebSocket, Query
from fastapi.middleware.cors import CORSMiddleware

from app.db import init_db, get_db
from app.asr_handler import handle_asr_websocket
from app.schemas import HistoryItem

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    logger.info("数据库初始化完成")
    yield


app = FastAPI(title="ASR Agent", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.websocket("/ws/asr")
async def websocket_asr(websocket: WebSocket):
    """实时语音识别 WebSocket 端点。
    客户端发送二进制音频帧，服务端返回 JSON 识别结果。
    """
    await handle_asr_websocket(websocket)


@app.get("/api/history")
async def get_history(
    session_id: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=200),
):
    """获取历史识别记录。"""
    db = await get_db()
    if session_id:
        cursor = await db.execute(
            "SELECT * FROM asr_history WHERE session_id = ? ORDER BY created_at DESC LIMIT ?",
            (session_id, limit),
        )
    else:
        cursor = await db.execute(
            "SELECT * FROM asr_history ORDER BY created_at DESC LIMIT ?",
            (limit,),
        )
    rows = await cursor.fetchall()
    await db.close()
    return [
        HistoryItem(
            id=row["id"],
            session_id=row["session_id"],
            text=row["text"],
            is_command=bool(row["is_command"]),
            command_result=row["command_result"],
            created_at=row["created_at"],
        )
        for row in rows
    ]


@app.get("/api/health")
async def health():
    return {"status": "ok"}
