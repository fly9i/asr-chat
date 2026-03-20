import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ASRViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if viewModel.appState == .idle && viewModel.sentences.isEmpty && viewModel.chatEvents.isEmpty {
                                    HistoryListView(history: viewModel.history)
                                } else {
                                    RecognitionResultView(sentences: viewModel.sentences)

                                    // Chat 事件展示
                                    if !viewModel.chatEvents.isEmpty {
                                        ChatEventsView(events: viewModel.chatEvents, isBusy: viewModel.isChatBusy)
                                    }
                                }

                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding()
                        }
                        .onChange(of: viewModel.sentences.count) {
                            withAnimation { proxy.scrollTo("bottom") }
                        }
                        .onChange(of: viewModel.chatEvents.count) {
                            withAnimation { proxy.scrollTo("bottom") }
                        }
                    }

                    Divider()

                    ControlBarView(viewModel: viewModel)
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("ASR Agent")
            .navigationBarTitleDisplayMode(.inline)
            // 权限确认弹窗
            .alert("权限确认", isPresented: Binding(
                get: { viewModel.pendingConfirm != nil },
                set: { if !$0 { viewModel.pendingConfirm = nil } }
            )) {
                Button("允许") { viewModel.respondToConfirm(response: "once") }
                Button("始终允许") { viewModel.respondToConfirm(response: "always") }
                Button("拒绝", role: .destructive) { viewModel.respondToConfirm(response: "reject") }
            } message: {
                Text(viewModel.pendingConfirm?.confirmMessage ?? "")
            }
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

    var body: some View {
        ForEach(sentences) { sentence in
            Text(sentence.text)
                .font(.body)
                .foregroundStyle(sentence.isFinal ? .primary : .secondary)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Chat 事件展示

struct ChatEventsView: View {
    let events: [ChatDisplayItem]
    let isBusy: Bool

    var body: some View {
        Divider().padding(.vertical, 8)

        VStack(alignment: .leading, spacing: 10) {
            Text("指令执行")
                .font(.headline)

            ForEach(events) { item in
                chatItemView(item)
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("处理中...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func chatItemView(_ item: ChatDisplayItem) -> some View {
        switch item.type {
        case .thinking:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(.purple)
                    .frame(width: 20)
                Text(item.content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }

        case .text:
            Text(item.content)
                .font(.body)
                .textSelection(.enabled)

        case .tool:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                Text(item.content)
                    .font(.callout.monospaced())
                    .lineLimit(10)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .subtask:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.blue)
                    .frame(width: 20)
                Text(item.content)
                    .font(.callout)
            }
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
                if viewModel.sentences.isEmpty && viewModel.chatEvents.isEmpty {
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
                Button(action: { viewModel.stopRecording() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                }

                RecordingIndicator()

                Spacer()

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
