# ASR Agent

## 介绍
基于语音的 AI 智能交互代理，通过前端、应用录音上传，通过 Fun-Asr 实时语音识别回显。实时响应用户需求，使用工具、skill等能力，提供智能化的服务。

## 功能
- 实时语音识别：通过 Fun-Asr 实现高准确率的语音转文本功能，支持多种语言和方言。
- 智能交互：基于用户的语音输入，智能分析用户需求，调用相关工具和技能，提供个性化的服务。
- 多模态支持：不仅支持语音输入，还可以处理图片等多模态数据，增强交互体验。


## 技术架构

### 后端实现
- 语音识别模块：集成 Fun-Asr 实现实时语音转文本功能。
  1. websocket 接口实时接收客户端发送的音频数据。
  2. 将音频数据传递给 Fun-Asr 模型进行处理。
  3. 将识别结果实时返回给客户端，提供即时反馈。

fun-asr 调用参考代码:
```python
import os
import time
import dashscope
from dashscope.audio.asr import *

# 新加坡和北京地域的API Key不同。获取API Key：https://help.aliyun.com/zh/model-studio/get-api-key
# 若没有配置环境变量，请用百炼API Key将下行替换为：dashscope.api_key = "sk-xxx"
dashscope.api_key = os.environ.get('DASHSCOPE_API_KEY')

# 以下为北京地域url，若使用新加坡地域的模型，需将url替换为：wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference
dashscope.base_websocket_api_url = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference'

from datetime import datetime


def get_timestamp():
    now = datetime.now()
    formatted_timestamp = now.strftime("[%Y-%m-%d %H:%M:%S.%f]")
    return formatted_timestamp


class Callback(RecognitionCallback):
    def on_complete(self) -> None:
        print(get_timestamp() + ' Recognition completed')  # recognition complete

    def on_error(self, result: RecognitionResult) -> None:
        print('Recognition task_id: ', result.request_id)
        print('Recognition error: ', result.message)
        exit(0)

    def on_event(self, result: RecognitionResult) -> None:
        sentence = result.get_sentence()
        if 'text' in sentence:
            print(get_timestamp() + ' RecognitionCallback text: ', sentence['text'])
        if RecognitionResult.is_sentence_end(sentence):
            print(get_timestamp() +
                  'RecognitionCallback sentence end, request_id:%s, usage:%s'
                  % (result.get_request_id(), result.get_usage(sentence)))


callback = Callback()

recognition = Recognition(model='fun-asr-realtime',
                          format='wav',
                          sample_rate=16000,
                          callback=callback)

try:
    audio_data: bytes = None
    f = open("asr_example.wav", 'rb')
    if os.path.getsize("asr_example.wav"):
        # 一次性将文件数据全部读入buffer
        file_buffer = f.read()
        f.close()
        print("Start Recognition")
        recognition.start()

        # 从buffer中间隔3200字节发送一次
        buffer_size = len(file_buffer)
        offset = 0
        chunk_size = 3200

        while offset < buffer_size:
            # 计算本次要发送的数据块大小
            remaining_bytes = buffer_size - offset
            current_chunk_size = min(chunk_size, remaining_bytes)

            # 从buffer中提取当前数据块
            audio_data = file_buffer[offset:offset + current_chunk_size]

            # 发送音频数据帧
            recognition.send_audio_frame(audio_data)
            # 更新偏移量
            offset += current_chunk_size

            # 添加延迟模拟实时传输
            time.sleep(0.1)

        recognition.stop()
    else:
        raise Exception(
            'The supplied file was empty (zero bytes long)')
except Exception as e:
    raise e

print(
    '[Metric] requestId: {}, first package delay ms: {}, last package delay ms: {}'
    .format(
        recognition.get_last_request_id(),
        recognition.get_first_package_delay(),
        recognition.get_last_package_delay(),
    ))
```


### ios app实现
1. 实现音频录制功能，支持实时录音并将音频数据发送到后端。
2. 通过 websocket 接口与后端进行通信，实时接收语音识别结果并在界面上显示。
  * fun-asr 有滑动窗口的语音识别修复，可以在用户说话过程中不断优化识别结果，回显需要支持实时修正更新。
3. 设计友好的用户界面，提供清晰的交互反馈，增强用户体验。
4. 对于用户指令支持实时显示执行过程
  * ai 思考过程
  * 工具调用过程
  * skill 执行过程
  * 最终结果展示
 5. 页面交互
   * 初始界面上部显示历史记录，下部是开始录音按钮
   * 点击开始录音后，按钮变为停止录音，并以一个动画的形式，移到页面最下方左侧，上方变成现实录音识别结果，指令执行状态等
   * 录音过程，在停止录音按钮右侧显示一个指令执行按钮，点击后变为“指令结束”，录音状态不变，但是直到点击“指令结束”后，这段过程的录音识别结果作为指令输入，传给后端进行处理
   * 录音过程，页面上部显示识别结果，用户可以看到实时的识别文本
   * 如果执行指令，则显示指令执行的过程和结果，过程参见 4
   * 录音结束后，按钮变成继续录音

## 其他功能
- 支持指令识别
识别方式:
1. 通过关键词触发：用户在语音中包含特定关键词（如“开始”），系统识别到关键词后等待结束指令（如“停止”），识别中间的指令。
2. 通过语义理解触发：不断地将最近的语音输入传给一个小模型，让它判断用户是否在下达指令，如果是，则将指令内容传给后端进行处理。
3. 通过界面按钮触发：用户点击界面上的按钮开始记录，直到再次点击停止，识别这段时间内的语音指令。

目前优先实现第3种方式，后续可以根据用户使用习惯增加第1、2种方式。
