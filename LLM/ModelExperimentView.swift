import SwiftUI

struct ModelExperimentView: View {
    @Bindable var chat: LocalChatModel
    @Bindable var rag: LocalRAGModel
    @State private var experiment = ModelExperimentController()
    @State private var task: Task<Void, Never>?
    @State private var starting = false

    private var blocked: Bool { starting || experiment.isRunning || experiment.isLoading || chat.isBusy || rag.isBusy }
    var body: some View {
        Form {
            Section("Deney ayarları") {
                Picker("Model", selection: $experiment.model) {
                    ForEach(LocalModelChoice.allCases.filter { $0 != .apple }) { model in Text(model.title).tag(model) }
                }.disabled(blocked)
                TextField("Soru", text: $experiment.prompt, axis: .vertical).disabled(blocked)
                Picker("Başlangıç", selection: $experiment.mode) {
                    Text("Soğuk").tag("cold")
                    Text("Isıtılmış").tag("warm")
                }.disabled(blocked)
                Text("Token sınırı: \(experiment.model.responseTokenLimit) · Sıcaklık: 0,6")
                Text("Isıtılmış ölçümden önce kayda alınmayan bir hazırlık yanıtı üretilir. İlk indirmede hazırlık süresine indirme de dahil olabilir.")
                    .font(.caption)
                if starting || experiment.isRunning {
                    Button("Durdur") { task?.cancel() }
                } else {
                    Button("Çalıştır ve kaydet", action: start).disabled(blocked)
                }
            }
            if let error = experiment.errorMessage { Text(error).foregroundStyle(.red) }
            if !experiment.output.isEmpty { Section("Yanıt") { Text(experiment.output).textSelection(.enabled) } }
            Section("Kaydedilmiş deneyler") {
                ForEach(experiment.records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(record.definition.modelId) · \(record.definition.mode) · \(record.status)").font(.caption)
                        Text(record.definition.prompt)
                        Text("Hazırlık: \(Int(record.metrics.preparationMs)) ms · Üretim: \(Int(record.metrics.generationMs)) ms").font(.caption)
                        Button("Aynı ayarlarla tekrar çalıştır") {
                            experiment.restore(record)
                            if experiment.errorMessage == nil { start() }
                        }.disabled(blocked)
                        if let data = try? JSONEncoder().encode(record), let text = String(data: data, encoding: .utf8) {
                            ShareLink("JSON paylaş", item: text)
                        }
                    }
                }
            }
        }
        .navigationTitle("Model deneyi")
    }

    private func start() {
        guard !blocked else { return }
        starting = true
        chat.isManagingModels = true
        rag.isManagingModels = true
        task = Task {
            defer { starting = false; chat.isManagingModels = false; rag.isManagingModels = false; task = nil }
            await chat.releaseForModelManagement()
            rag.unloadEmbedder()
            guard !Task.isCancelled else { return }
            await experiment.run()
        }
    }
}
