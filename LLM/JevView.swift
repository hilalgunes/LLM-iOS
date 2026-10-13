import SwiftUI

struct JevView: View {
    @Bindable var chat: LocalChatModel
    @Bindable var jev: JevModel
    @Bindable var history: ConversationHistoryStore
    @State private var isShowingHistory = false

    private var canRun: Bool {
        !jev.stateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !jev.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !jev.selectedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !jev.isBusy
            && !chat.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    apiKeyCard
                    inputCard

                    if let statusMessage = jev.statusMessage {
                        statusCard(statusMessage)
                    }

                    if let result = jev.jevAnswer {
                        jevResultCard(result)
                    }

                    if !jev.localExplanation.isEmpty {
                        explanationCard
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryListView(history: history)
        }
        .alert(
            "Jev işlemi başarısız",
            isPresented: Binding(
                get: { jev.errorMessage != nil },
                set: { if !$0 { jev.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {
                jev.errorMessage = nil
            }
        } message: {
            if let errorMessage = jev.errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Jev değerlendirmesi")
                    .font(.headline)
                Text("\(jev.provider.title), ardından yerel model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isShowingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(.indigo.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Sohbet geçmişi")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Değerlendirme modeli", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            Picker("Sağlayıcı", selection: $jev.provider) {
                ForEach(JevProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .disabled(jev.isBusy || chat.isBusy)

            Text(jev.provider == .typeSafe ? "TypeSafe AI API anahtarı" : "Liquid d1 API anahtarı")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Group {
                if jev.provider == .typeSafe {
                    SecureField("Jev API anahtarını girin", text: $jev.apiKey)
                } else {
                    SecureField("Liquid API anahtarını girin", text: $jev.liquidAPIKey)
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Button {
                    if jev.provider == .typeSafe {
                        jev.saveAPIKey()
                    } else {
                        jev.saveLiquidAPIKey()
                    }
                } label: {
                    Label("Anahtarı kaydet", systemImage: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.indigo, in: Capsule())
                }

                if jev.hasSavedSelectedAPIKey {
                    Button(role: .destructive) {
                        if jev.provider == .typeSafe {
                            jev.deleteAPIKey()
                        } else {
                            jev.deleteLiquidAPIKey()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 42, height: 42)
                            .background(.red.opacity(0.1), in: Circle())
                    }
                    .accessibilityLabel("Kaydedilmiş API anahtarını sil")
                }
            }

            Label(
                jev.hasSavedSelectedAPIKey
                    ? "Anahtar bu cihazın Anahtar Zinciri'nde saklanıyor."
                    : "Seçili sağlayıcının anahtarı henüz kaydedilmedi.",
                systemImage: jev.hasSavedSelectedAPIKey ? "checkmark.shield.fill" : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(jev.hasSavedSelectedAPIKey ? .green : .secondary)

            if jev.provider == .liquidD1 {
                Text("Liquid API anahtarı console.liquid.ai üzerinden alınır. Değerlendirme için içerik Liquid sunucusuna gönderilir.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Değerlendirme", systemImage: "text.magnifyingglass")
                .font(.headline)

            Text("İçerik")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $jev.stateText)
                .frame(minHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            Text("Jev'e sorulacak soru")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Örn. Bu içerik acil bir durum gösteriyor mu?", text: $jev.instructions, axis: .vertical)
                .lineLimit(2...4)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            Picker("Yanıt türü", selection: $jev.questionType) {
                ForEach(JevQuestionType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)

            if jev.questionType != .noul {
                VStack(alignment: .leading, spacing: 6) {
                    Text(jev.questionType == .choice ? "Seçenekler · her satıra `anahtar: açıklama`" : "Puan ölçeği · en düşükten en yükseğe")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $jev.criteriaText)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .topLeading) {
                            if jev.criteriaText.isEmpty {
                                Text(jev.questionType == .choice
                                     ? "acil: hemen ilgilenilmeli\nnormal: rutin işlem\nbilgi: yalnızca bilgi isteği"
                                     : "Düşük\nOrta\nYüksek\nKritik")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Yerel açıklama modeli")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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
                    }
                } label: {
                    HStack {
                        Text(chat.selectedModel.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(jev.isBusy || chat.isBusy)
            }

            Button {
                Task { await jev.run(using: chat, history: history) }
            } label: {
                HStack {
                    if jev.isBusy || chat.isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    Text("\(jev.provider.title)'e gönder ve yerelde açıkla")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(canRun ? Color.indigo : Color.gray, in: Capsule())
            }
            .disabled(!canRun)

            Label(
                jev.provider == .typeSafe
                    ? "İçerik TypeSafe Jev API'ye gönderilir. Yerel model açıklamayı cihazında üretir."
                    : "İçerik Liquid d1 API'ye gönderilir. Bu sağlayıcı internet gerektirir; yerel model açıklamayı cihazında üretir.",
                systemImage: "arrow.up.forward.app"
            )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func jevResultCard(_ result: JevAnswer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(jev.providerResultTitle, systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if let version = jev.jevModelVersion {
                    Text(version)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(result.summary)
                .font(.title3.weight(.semibold))

            if let probabilities = result.probabilities, !probabilities.isEmpty {
                Divider()
                ForEach(probabilities.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(result.legend?[key] ?? key)
                            .font(.subheadline)
                        Spacer()
                        Text("\(((probabilities[key] ?? 0) * 100).formatted(.number.precision(.fractionLength(1))))%")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(jev.explanationProviderTitle) sonucunun yerel açıklaması", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.indigo)
            Text(chat.isLoadingModel ? "Yerel model indiriliyor…" : jev.localExplanation)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chat.isLoadingModel {
                ProgressView(value: chat.downloadProgress)
                    .tint(.indigo)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func statusCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.orange)
            Text(message)
                .font(.subheadline)
            Spacer()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}
