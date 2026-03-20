# ASR Agent

基于语音的 AI 智能交互代理。通过客户端录音上传，后端集成 DashScope Fun-ASR 实时语音识别，支持实时回显和指令执行。

## 功能特性

- **实时语音识别** — 基于 DashScope Fun-ASR，支持滑动窗口实时修正
- **指令执行** — 录音过程中可标记指令段落，发送给后端处理
- **历史记录** — SQLite 存储识别和指令执行历史

## 项目结构

```
├── backend/             # Python 后端
│   ├── app/
│   │   ├── main.py          # FastAPI 应用入口
│   │   ├── asr_handler.py   # WebSocket + DashScope ASR 核心
│   │   ├── config.py        # 环境变量配置
│   │   ├── db.py            # SQLite 数据库
│   │   └── schemas.py       # 数据模型
│   ├── main.py              # uvicorn 启动入口
│   └── pyproject.toml       # uv 项目配置
└── ios/ASRAgent/        # iOS 客户端 (SwiftUI)
    └── ASRAgent/
        ├── ContentView.swift        # 主界面
        ├── Models/ASRMessage.swift  # 数据模型
        └── Services/
            ├── AudioRecorder.swift      # AVAudioEngine 录音
            ├── WebSocketManager.swift   # WebSocket 通信
            └── ASRViewModel.swift       # 核心 ViewModel
```

## 快速开始

### 后端

```bash
cd backend
cp .env.example .env
# 编辑 .env，填入 DASHSCOPE_API_KEY
uv run python main.py
```

服务启动在 `http://0.0.0.0:8000`。

### iOS

1. 用 Xcode 打开 `ios/ASRAgent/ASRAgent.xcodeproj`
2. 修改 `WebSocketManager.swift` 中的 `serverURL` 为后端实际地址
3. 运行到真机（需要麦克风权限）

## API

| 端点 | 说明 |
|------|------|
| `WS /ws/asr` | 实时语音识别 WebSocket（发送 PCM 音频帧，接收 JSON 识别结果） |
| `GET /api/history` | 查询历史记录（可选 `session_id`、`limit` 参数） |
| `GET /api/health` | 健康检查 |

### WebSocket 消息格式

**服务端 → 客户端：**
```json
{"type": "partial", "text": "你好", "sentence_id": 1}
{"type": "final", "text": "你好世界", "sentence_id": 1}
{"type": "command_status", "status": "thinking", "content": "收到指令: ..."}
{"type": "command_result", "status": "result", "content": "执行完成: ..."}
```

**客户端 → 服务端：**
- 二进制帧：PCM 16kHz 16bit 单声道音频数据
- 文本帧：`{"action": "stop"}` 或 `{"action": "execute_command", "text": "..."}`

## 技术栈

- **后端：** Python / FastAPI / DashScope SDK / SQLite / uv
- **iOS：** SwiftUI / AVAudioEngine / URLSession WebSocket
