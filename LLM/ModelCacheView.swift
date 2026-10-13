import SwiftUI

struct ModelCacheView: View {
    @Bindable var manager: ModelCacheManager
    @Bindable var chat: LocalChatModel
    @Bindable var rag: LocalRAGModel
    @Environment(\.dismiss) private var dismiss
    @State private var modelToDelete: ManagedModel?

    private var totalSize: Int64 {
        manager.sizes.values.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Toplam indirilen model", systemImage: "internaldrive.fill")
                        Spacer()
                        Text(totalSize.formattedStorageSize)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                    Text("Kullanılan alan Hugging Face model önbelleğinden hesaplanır. Silinen model gerektiğinde tekrar indirilebilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(["Sohbet", "Embedding"], id: \.self) { category in
                    let categoryModels = manager.models.filter { $0.category == category }
                    if !categoryModels.isEmpty {
                        Section(category) {
                            ForEach(categoryModels) { model in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.title)
                                            .font(.subheadline.weight(.medium))
                                        Text(manager.sizes[model.id, default: 0].formattedStorageSize)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if manager.sizes[model.id, default: 0] > 0 {
                                        Button(role: .destructive) {
                                            modelToDelete = model
                                        } label: {
                                            Image(systemName: "trash")
                                                .frame(width: 36, height: 36)
                                                .background(.red.opacity(0.1), in: Circle())
                                        }
                                        .accessibilityLabel("\(model.title) modelini sil")
                                    } else {
                                        Text("İndirilmedi")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .overlay {
                if manager.isRefreshing {
                    ProgressView("Önbellek taranıyor…")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("İndirilen modeller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Bitti") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manager.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(manager.isRefreshing)
                }
            }
            .confirmationDialog(
                "Model önbelleğini sil?",
                isPresented: Binding(
                    get: { modelToDelete != nil },
                    set: { if !$0 { modelToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Modeli sil", role: .destructive) {
                    if let modelToDelete {
                        manager.delete(modelToDelete, chat: chat, rag: rag)
                    }
                    modelToDelete = nil
                }
                Button("İptal", role: .cancel) {
                    modelToDelete = nil
                }
            } message: {
                if let modelToDelete {
                    Text("\(modelToDelete.title) önbelleği silinecek. Daha sonra tekrar indirilebilir.")
                }
            }
            .alert(
                "Model yönetimi",
                isPresented: Binding(
                    get: { manager.errorMessage != nil },
                    set: { if !$0 { manager.errorMessage = nil } }
                )
            ) {
                Button("Tamam", role: .cancel) {
                    manager.errorMessage = nil
                }
            } message: {
                if let errorMessage = manager.errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
}
