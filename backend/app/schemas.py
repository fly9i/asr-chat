from pydantic import BaseModel
from typing import Optional


class ASRMessage(BaseModel):
    """从服务端发送给客户端的 WebSocket 消息"""
    type: str  # partial | final | command_status | command_result | error
    text: str = ""
    sentence_id: int = 0
    status: str = ""  # thinking | tool_call | skill | result
    content: str = ""


class HistoryItem(BaseModel):
    id: int
    session_id: str
    text: str
    is_command: bool = False
    command_result: Optional[str] = None
    created_at: str
