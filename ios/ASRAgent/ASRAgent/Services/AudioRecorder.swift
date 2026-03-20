import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "com.asragent.app", category: "Audio")

/// 使用 AVAudioEngine 进行实时录音，输出 PCM 16kHz 16bit 单声道数据
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }
    private var frameCount = 0
    private var byteCount = 0

    /// 音频数据回调，每次产生一段 PCM 数据
    var onAudioData: ((Data) -> Void)?

    func startRecording() {
        guard !isRecording else { return }
        frameCount = 0
        byteCount = 0

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            audioLog.info("音频会话配置成功")
        } catch {
            audioLog.error("音频会话配置失败: \(error.localizedDescription)")
            return
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        audioLog.info("输入格式: sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            audioLog.error("无法创建目标音频格式")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            audioLog.error("无法创建音频格式转换器 from \(inputFormat) to \(targetFormat)")
            return
        }
        audioLog.info("音频转换器创建成功: \(inputFormat.sampleRate)Hz -> 16000Hz")

        inputNode.installTap(onBus: 0, bufferSize: 3200, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try audioEngine.start()
            audioLog.info("录音引擎启动成功")
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            audioLog.error("音频引擎启动失败: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioLog.info("录音停止, 总计 \(self.frameCount) 帧, \(self.byteCount) 字节")
        DispatchQueue.main.async { self.isRecording = false }
    }

    private func convertAndSend(buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                 targetFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            audioLog.error("无法创建转换缓冲区")
            return
        }

        var error: NSError?
        var hasData = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasData = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            audioLog.error("音频转换失败: \(error.localizedDescription)")
            return
        }

        guard let channelData = convertedBuffer.int16ChannelData else {
            audioLog.error("转换后无有效音频数据")
            return
        }
        let data = Data(
            bytes: channelData[0],
            count: Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        )

        self.frameCount += 1
        self.byteCount += data.count
        if self.frameCount % 50 == 1 {
            audioLog.info("[录音] 帧 #\(self.frameCount), 本次=\(data.count)字节, 累计=\(self.byteCount)字节")
        }

        onAudioData?(data)
    }
}
