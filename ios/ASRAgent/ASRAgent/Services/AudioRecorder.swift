import AVFoundation
import Foundation

/// 使用 AVAudioEngine 进行实时录音，输出 PCM 16kHz 16bit 单声道数据
class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }

    /// 音频数据回调，每次产生一段 PCM 数据
    var onAudioData: ((Data) -> Void)?

    func startRecording() {
        guard !isRecording else { return }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("音频会话配置失败: \(error)")
            return
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        // 目标格式: PCM 16kHz 16bit 单声道
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else { return }

        // 安装格式转换器
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("无法创建音频格式转换器")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 3200, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try audioEngine.start()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            print("音频引擎启动失败: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        DispatchQueue.main.async { self.isRecording = false }
    }

    private func convertAndSend(buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                 targetFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
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
            print("音频转换失败: \(error)")
            return
        }

        guard let channelData = convertedBuffer.int16ChannelData else { return }
        let data = Data(
            bytes: channelData[0],
            count: Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        )
        onAudioData?(data)
    }
}
