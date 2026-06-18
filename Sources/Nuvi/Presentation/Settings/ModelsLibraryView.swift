import SwiftUI

struct ModelsLibraryView: View {
    @ObservedObject private var downloadService = ModelDownloadService.shared
    @ObservedObject private var loc = LocalizationStore.shared
    @State private var selectedFilter: FilterType = .all
    @State private var activeModelId: String = SettingsStore.shared.selectedModelID

    enum FilterType: String, CaseIterable, Identifiable {
        case all, whisper, parakeet, downloaded

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return tr("All", "Todos")
            case .whisper: return "Whisper"
            case .parakeet: return "Parakeet"
            case .downloaded: return tr("Downloaded", "Descargados")
            }
        }
    }

    var filteredModels: [AppModel] {
        downloadService.catalog.filter { model in
            switch selectedFilter {
            case .all:
                return true
            case .whisper:
                return model.engine == .whisperKit
            case .parakeet:
                return model.engine == .parakeet
            case .downloaded:
                return downloadService.downloadedModels.contains(model.id)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Cabecera: Título y Selector de Filtros
            HStack {
                Text(tr("Models Library", "Biblioteca de Modelos"))
                    .font(.title2)
                    .bold()

                Spacer()

                Picker("", selection: $selectedFilter) {
                    ForEach(FilterType.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }

            // Descripción general
            Text(tr("Choose the engine and model that fit your workflow. Whisper (OpenAI) offers higher-accuracy variants at more cost; Parakeet (FluidAudio) prioritizes multilingual speed. Activating a model switches Nuvi to its engine automatically.",
                    "Elegí el motor y modelo que mejor se adapte a tu flujo. Whisper (OpenAI) ofrece variantes de mayor precisión a más costo; Parakeet (FluidAudio) prioriza velocidad multilingüe. Al activar un modelo, Nuvi cambia automáticamente al motor correspondiente."))
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Banner de error, si lo hay
            if let error = downloadService.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { downloadService.lastError = nil }) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // Grid de Cards con scroll
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(filteredModels) { model in
                        ModelCardView(
                            model: model,
                            isDownloaded: downloadService.downloadedModels.contains(model.id),
                            isActive: activeModelId == model.id,
                            activity: downloadActivity(for: model),
                            onDownload: {
                                downloadService.startDownload(modelId: model.id)
                            },
                            onCancel: {
                                downloadService.cancelDownload(modelId: model.id)
                            },
                            onSelect: {
                                activate(model)
                            },
                            onDelete: {
                                downloadService.deleteModel(modelId: model.id)
                                // Si eliminamos el activo, volvemos a tiny por seguridad
                                if activeModelId == model.id {
                                    SettingsStore.shared.selectedModelID = "openai_whisper-tiny"
                                    SettingsStore.shared.enginePreference = .whisperKit
                                    activeModelId = "openai_whisper-tiny"
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .onAppear {
            downloadService.refreshDownloadedModels()
            activeModelId = SettingsStore.shared.selectedModelID
        }
    }

    /// Activating a model also switches the engine so the runtime loads the right
    /// backend for the selected model id.
    private func activate(_ model: AppModel) {
        SettingsStore.shared.selectedModelID = model.id
        SettingsStore.shared.enginePreference = (model.engine == .parakeet) ? .parakeet : .whisperKit
        activeModelId = model.id
    }

    private func downloadActivity(for model: AppModel) -> DownloadActivity? {
        if downloadService.indeterminateDownloads.contains(model.id) {
            return .indeterminate
        }
        if let fraction = downloadService.downloadProgress[model.id] {
            return .determinate(fraction)
        }
        return nil
    }
}
