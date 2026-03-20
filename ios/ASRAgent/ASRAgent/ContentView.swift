import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ASRViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    // 上部：历史记录 / 识别结果 / 指令执行状态
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if viewModel.appState == .idle && viewModel.sentences.isEmpty {
                                    HistoryListView(history: viewModel.history)
                                } else {
                                    RecognitionResultView(
                                        sentences: viewModel.sentences,
                                        commandRecord: viewModel.currentCommand
                                    )
                                }
                            }
                            .padding()
                            .id("content")
                        }
                        .onChange(of: viewModel.sentences.count) {
                            withAnimation {
                                proxy.scrollTo("content", anchor: .bottom)
                            }
                        }
                    }

                    Divider()

                    // 下部：控制按钮区域
                    ControlBarView(viewModel: viewModel)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("ASR Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            viewModel.loadHistory()
        }
    }
}

// MARK: - 历史记录列表

struct HistoryListView: View {
    let history: [HistoryItem]

    var body: some View {
        if history.isEmpty {
            VStack(spacing: 16) {
                Spacer(minLength: 100)
                Image(systemName: "waveform.circle")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
                Text("点击下方按钮开始录音")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ForEach(history) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text)
                        .font(.body)
                    Text(item.createdAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let result = item.commandResult {
                        Text("指令结果: \(result)")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - 识别结果

struct RecognitionResultView: View {
    let sentences: [RecognizedSentence]
    let commandRecord: CommandRecord?

    var body: some View {
        // 实时识别文本
        ForEach(sentences) { sentence in
            Text(sentence.text)
                .font(.body)
                .foregroundStyle(sentence.isFinal ? .primary : .secondary)
                .padding(.vertical, 2)
        }

        // 指令执行过程
        if let command = commandRecord, !command.steps.isEmpty {
            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("指令执行")
                    .font(.headline)

                ForEach(command.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconForStatus(step.status))
                            .foregroundStyle(colorForStatus(step.status))
                            .frame(width: 20)
                        Text(step.content)
                            .font(.callout)
                    }
                }

                if command.isComplete {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("执行完成")
                            .font(.callout)
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func iconForStatus(_ status: String) -> String {
        switch status {
        case "thinking": return "brain"
        case "tool_call": return "wrench.and.screwdriver"
        case "skill": return "sparkles"
        case "result": return "checkmark.circle"
        default: return "circle"
        }
    }

    private func colorForStatus(_ status: String) -> Color {
        switch status {
        case "thinking": return .purple
        case "tool_call": return .orange
        case "skill": return .blue
        case "result": return .green
        default: return .secondary
        }
    }
}

// MARK: - 控制栏

struct ControlBarView: View {
    @ObservedObject var viewModel: ASRViewModel

    var body: some View {
        HStack(spacing: 16) {
            switch viewModel.appState {
            case .idle:
                if viewModel.sentences.isEmpty {
                    // 初始状态：只显示开始录音
                    Spacer()
                    Button(action: { viewModel.startRecording() }) {
                        Label("开始录音", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                    Spacer()
                } else {
                    // 暂停状态：显示继续录音 + 结束任务
                    Button(action: { viewModel.finishSession() }) {
                        Label("结束任务", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(.gray)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Button(action: { viewModel.startRecording(resume: true) }) {
                        Label("继续录音", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                }

            case .recording:
                // 停止录音按钮（左侧）
                Button(action: { viewModel.stopRecording() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                }

                // 录音动画指示
                RecordingIndicator()

                Spacer()

                // 指令按钮（右侧）
                if viewModel.isCommandMode {
                    Button(action: { viewModel.endCommand() }) {
                        Text("开始执行")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.orange)
                            .clipShape(Capsule())
                    }
                } else {
                    Button(action: { viewModel.startCommand() }) {
                        Text("执行指令")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.blue)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - 录音动画指示器

struct RecordingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.red.opacity(0.7))
                    .frame(width: 4, height: animating ? CGFloat.random(in: 8...24) : 8)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever()
                        .delay(Double(i) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}
