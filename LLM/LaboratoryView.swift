import SwiftUI

struct LaboratoryView: View {
    @Bindable var chat: LocalChatModel
    @Bindable var rag: LocalRAGModel
    @Bindable var jev: JevModel
    @Bindable var history: ConversationHistoryStore

    var body: some View {
        NavigationStack {
            List {
                Section("Model ölçümleri") {
                    NavigationLink("Tekrarlanabilir model deneyi") { ModelExperimentView(chat: chat, rag: rag) }
                }
                Section("Arama deneyleri") {
                    NavigationLink("Embedding karşılaştırması") {
                        RAGView(chat: chat, rag: rag, history: history, laboratoryMode: true)
                    }
                    NavigationLink("Jev deneyleri") {
                        JevView(chat: chat, jev: jev, history: history)
                    }
                }
                Section("Kayıtlar") {
                    NavigationLink("Deney sonuçları") { ResultsView(history: history) }
                }
            }
            .navigationTitle("Laboratuvar")
        }
    }
}
