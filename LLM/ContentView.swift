import SwiftUI

struct ContentView: View {
    @State private var chat = LocalChatModel()
    @State private var rag = LocalRAGModel()
    @State private var jev = JevModel()
    @State private var history = ConversationHistoryStore()
    @State private var voice = VoiceChatController()
    @State private var modelCache = ModelCacheManager()
    @State private var selectedTab = 0
    @State private var question = ""
    @FocusState private var questionFieldFocused: Bool
    @State private var isShowingHistory = false
    @State private var isShowingThreads = false
    @State private var isShowingModels = false

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedTab == 0 {
                chatScreen
            } else if selectedTab == 1 {
                RAGView(chat: chat, rag: rag, history: history)
            } else if selectedTab == 2 {
                JevView(chat: chat, jev: jev, history: history)
            } else {
                ResultsView(history: history)
            }
            bottomBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            chat.attachHistory(history)
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != 1 {
                rag.unloadEmbedder()
            }
            if newValue == 1 {
                chat.unloadModel()
            }
        }
    }

    private var chatScreen: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 18) {
                    if chat.messages.isEmpty {
                        welcomeCard
                    } else {
                        ForEach(chat.messages) { message in
                            MessageBubble(message: message)
                        }
                    }

                    if chat.isLoadingModel {
                        downloadCard
                    }

                    if chat.isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.indigo)
                            Text("Yanıt hazırlanıyor…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }

                    if voice.isGeneratingSpeech {
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.indigo)
                            Text("Türkçe ses hazırlanıyor; EMA ilk kullanımda model dosyalarını indirir…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)

            composer
        }
        .alert(
            "Bir hata oluştu",
            isPresented: Binding(
                get: { chat.errorMessage != nil },
                set: { if !$0 { chat.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {
                chat.errorMessage = nil
            }
        } message: {
            if let errorMessage = chat.errorMessage {
                Text(errorMessage)
            }
        }
        .alert(
            "Ses işlemi",
            isPresented: Binding(
                get: { voice.errorMessage != nil },
                set: { if !$0 { voice.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {
                voice.errorMessage = nil
            }
        } message: {
            if let errorMessage = voice.errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Sohbet", icon: "bubble.left.and.bubble.right.fill", index: 0)
            tabButton(title: "RAG", icon: "doc.text.magnifyingglass", index: 1)
            tabButton(title: "Jev", icon: "point.3.connected.trianglepath.dotted", index: 2)
            tabButton(title: "Sonuçlar", icon: "chart.bar.xaxis", index: 3)
        }
        .padding(.top, 9)
        .padding(.bottom, 5)
        .background(.regularMaterial)
        .sheet(isPresented: $isShowingHistory) {
            HistoryListView(history: history)
        }
        .sheet(isPresented: $isShowingThreads) {
            ChatThreadListView(
                history: history,
                onSelect: { chat.selectThread($0) },
                onNew: { chat.createThread() },
                onDelete: { chat.deleteThread($0) }
            )
        }
        .sheet(isPresented: $isShowingModels) {
            ModelCacheView(manager: modelCache, chat: chat, rag: rag)
        }
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(selectedTab == index ? Color.indigo : Color.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
        .disabled((chat.isBusy || rag.isBusy || jev.isBusy) && selectedTab != index)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Yerel Sohbet")
                    .font(.headline)
                Text(chat.activeThreadTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    isShowingThreads = true
                } label: {
                    Label("Sohbetleri aç", systemImage: "list.bullet.bubble")
                }
                Button {
                    chat.createThread()
                } label: {
                    Label("Yeni sohbet", systemImage: "plus")
                }
                Button {
                    isShowingHistory = true
                } label: {
                    Label("Tüm geçmiş", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    isShowingModels = true
                } label: {
                    Label("İndirilen modeller", systemImage: "internaldrive")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Sohbet ve model seçenekleri")

            Menu {
                ForEach(LocalModelChoice.allCases) { model in
                    Button {
                        chat.select(model)
                    } label: {
                        if chat.selectedModel == model {
                            Label(model.title, systemImage: "checkmark")
                        } else {
                            Text(model.title)
                        }
                    }
                    .disabled(chat.isBusy)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                    Text(chat.selectedModel.shortTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.indigo.opacity(0.1), in: Capsule())
            }
            .accessibilityLabel("Model seç: \(chat.selectedModel.title)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 27))
                .foregroundStyle(.indigo)
                .padding(13)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 7) {
                Text("Nasıl yardımcı olabilirim?")
                    .font(.title2.bold())
                Text("Bir soru yaz. Seçtiğin model ilk kullanımda indirilir ve yanıtını cihazında üretir.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Soruların bir sunucuya gönderilmez")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.green.opacity(0.1), in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.top, 30)
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.downloadProgress >= 1 ? "Model hazırlanıyor" : "Model indiriliyor")
                        .font(.subheadline.weight(.semibold))
                    Text(chat.selectedModel.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(chat.downloadProgress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.indigo)
            }
            ProgressView(value: chat.downloadProgress)
                .tint(.indigo)
            Text(
                chat.downloadProgress >= 1
                    ? "İndirme tamamlandı. Model cihaz belleğine yükleniyor; bu biraz sürebilir."
                    : "İndirme tamamlandığında model cihazında saklanır."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Bir soru sor…", text: $question, axis: .vertical)
                .lineLimit(1...5)
                .focused($questionFieldFocused)
                .submitLabel(.send)
                .onSubmit(sendQuestion)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                .onChange(of: voice.transcript) { _, transcript in
                    if !transcript.isEmpty {
                        question = transcript
                    }
                }

            Menu {
                Toggle("Yanıtları otomatik oku", isOn: $voice.speaksReplies)
                Toggle("EMA ONNX deneysel ses", isOn: $voice.usesEMASpeech)
            } label: {
                Image(systemName: voice.usesEMASpeech ? "waveform" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(voice.speaksReplies ? .indigo : .secondary)
                    .frame(width: 38, height: 46)
            }
            .accessibilityLabel("Seslendirme ayarları")

            Button {
                if voice.isRecording {
                    voice.stopRecording()
                    if !voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        question = voice.transcript
                    }
                } else {
                    question = ""
                    Task { await voice.startRecording() }
                }
            } label: {
                Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(voice.isRecording ? .red : .indigo)
                    .frame(width: 38, height: 46)
            }
            .disabled(chat.isBusy || voice.isFinishingRecognition)
            .accessibilityLabel(
                voice.isFinishingRecognition
                    ? "Söylenenler yazılıyor"
                    : voice.isRecording ? "Dikteyi bitir" : "Sesle soru sor"
            )

            Button(action: sendQuestion) {
                Image(systemName: chat.isBusy ? "ellipsis" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(canSend ? Color.indigo : Color.gray, in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Soruyu gönder")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.regularMaterial)
    }

    private func sendQuestion() {
        guard canSend else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        question = ""
        questionFieldFocused = false
        voice.beginStreamingReply()
        Task {
            if let result = await chat.send(prompt, onToken: { token in
                voice.appendReplyText(token)
            }) {
                if voice.usesEMASpeech {
                    chat.releaseModelForSpeech()
                }
                voice.finishStreamingReply()
                history.add(
                    kind: .chat,
                    title: prompt,
                    prompt: prompt,
                    answer: result.text,
                    modelName: chat.selectedModel.title,
                    totalDurationSeconds: result.totalDurationSeconds,
                    firstResponseSeconds: result.firstResponseSeconds
                )
            } else {
                voice.finishStreamingReply(success: false)
            }
        }
    }
}

private struct MessageBubble: View {
    let message: LocalChatMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            Text(message.text)
                .font(.body)
                .foregroundStyle(isUser ? .white : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    isUser ? Color.indigo : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20)
                )

            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
    }
}
