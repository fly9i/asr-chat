import os
from dotenv import load_dotenv

load_dotenv()

DASHSCOPE_API_KEY = os.getenv("DASHSCOPE_API_KEY", "")
DATABASE_PATH = os.getenv("DATABASE_PATH", "asr.db")
DASHSCOPE_WS_URL = os.getenv(
    "DASHSCOPE_WS_URL",
    "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
)
ASR_MODEL = os.getenv("ASR_MODEL", "paraformer-realtime-v2")
ASR_SAMPLE_RATE = int(os.getenv("ASR_SAMPLE_RATE", "16000"))
ASR_FORMAT = os.getenv("ASR_FORMAT", "pcm")
