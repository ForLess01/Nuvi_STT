import SwiftUI

/// Download state for a model card. `determinate` carries a 0...1 fraction
/// (WhisperKit), `indeterminate` is a running spinner (Parakeet via FluidAudio,
/// which exposes no progress).
enum DownloadActivity: Equatable {
    case determinate(Double)
    case indeterminate
}

struct ModelCardView: View {
    let model: AppModel
    let isDownloaded: Bool
    let isActive: Bool
    let isPaused: Bool
    let activity: DownloadActivity? // nil si no se está descargando

    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false
    @ObservedObject private var loc = LocalizationStore.shared

    private var isWhisper: Bool { model.engine == .whisperKit }
    private var accentColor: Color { NuviPalette.lavender }
    private var familyLabel: String { isWhisper ? "Whisper" : "Parakeet" }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Cabecera: Icono, Nombre, Estado Oficial
            HStack(alignment: .top, spacing: 12) {
                // Icono con fondo de color sutil
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: model.icon)
                        .font(.title3)
                        .foregroundColor(accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(familyLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.2))
                            .foregroundColor(accentColor)
                            .cornerRadius(4)
                    }
                    
                    Text(model.localizedDesc(spanish: loc.language == .spanish))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                // Botón interactivo
                actionButton
            }
            
            Divider()
                .background(NuviPalette.softWhite.opacity(0.1))
            
            // Estadísticas: Precisión y Velocidad en barras
            VStack(spacing: 12) {
                metricBar(
                    title: tr("Accuracy", "Precisión"),
                    value: model.accuracy,
                    valueText: String(format: "%.0f%%", model.accuracy * 100),
                    gradient: Gradient(colors: [NuviPalette.lavender, NuviPalette.softWhite])
                )

                metricBar(
                    title: tr("Speed", "Velocidad"),
                    value: model.speed,
                    valueText: String(format: "%.1fx RT", model.speed * 10),
                    gradient: Gradient(colors: [NuviPalette.lavender.opacity(0.62), NuviPalette.lavender])
                )
            }

            // Footer: RAM, disk size and delete button
            HStack {
                Text("RAM: ~\(formatBytes(model.ramBytes))  •  \(tr("Disk", "Disco")): \(formatBytes(model.sizeBytes))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                if isDownloaded && !isActive {
                    Button(action: { showDeleteConfirmation = true }) {
                        Image(systemName: "trash")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Delete from disk", "Eliminar del disco"))
                    .alert(isPresented: $showDeleteConfirmation) {
                        Alert(
                            title: Text(tr("Delete model?", "¿Eliminar modelo?")),
                            message: Text(tr("Remove '\(model.name)' from local storage?", "¿Seguro que querés eliminar el modelo '\(model.name)' del almacenamiento local?")),
                            primaryButton: .destructive(Text(tr("Delete", "Eliminar"))) {
                                onDelete()
                            },
                            secondaryButton: .cancel(Text(tr("Cancel", "Cancelar")))
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(NuviPalette.softWhite.opacity(0.03))
                .background(NuviPalette.charcoal.opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [NuviPalette.softWhite.opacity(0.1), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    // Botón de acción contextual
    @ViewBuilder
    private var actionButton: some View {
        if let activity {
            // Descarga en curso
            HStack(spacing: 8) {
                switch activity {
                case .determinate(let fraction):
                    CircularProgressView(progress: fraction)
                        .frame(width: 18, height: 18)
                case .indeterminate:
                    if isPaused {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundColor(NuviPalette.lavender.opacity(0.8))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if isPaused {
                    Button(action: onResume) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundColor(NuviPalette.lavender.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Resume download", "Reanudar descarga"))
                    .accessibilityLabel(tr("Resume download", "Reanudar descarga"))
                    .accessibilityHint(tr("Continue this download from its cached files.", "Continuar esta descarga desde sus archivos en caché."))
                } else {
                    Button(action: onPause) {
                        Image(systemName: "pause.fill")
                            .font(.title3)
                            .foregroundColor(NuviPalette.lavender.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help(tr("Pause download", "Pausar descarga"))
                    .accessibilityLabel(tr("Pause download", "Pausar descarga"))
                    .accessibilityHint(tr("Keep downloaded files and pause this operation.", "Conservar los archivos descargados y pausar esta operación."))
                }

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(NuviPalette.lavender.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(tr("Cancel download", "Cancelar descarga"))
                .accessibilityLabel(tr("Cancel download", "Cancelar descarga"))
                .accessibilityHint(tr("Stop this operation; cached partial files are kept.", "Detener esta operación; se conservan los archivos parciales en caché."))
            }
        } else if isDownloaded {
            if isActive {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(NuviPalette.lavender)
                    Text(tr("Active", "Activo"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(NuviPalette.lavender)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(NuviPalette.lavender.opacity(0.15))
                .cornerRadius(8)
            } else {
                Button(action: onSelect) {
                    Text(tr("Use", "Usar"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(NuviPalette.softWhite.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button(action: onDownload) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                    Text(tr("Download", "Descargar"))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(NuviPalette.charcoal)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(NuviPalette.softWhite)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }
    
    // Helper para barras de métrica
    private func metricBar(title: String, value: Double, valueText: String, gradient: Gradient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.primary)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(NuviPalette.softWhite.opacity(0.08))
                        .frame(height: 5)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                gradient: gradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(value), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
    
    // Formatear bytes a MB / GB
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// Circular progress indicator para descargas
struct CircularProgressView: View {
    let progress: Double
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(NuviPalette.softWhite.opacity(0.1), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                .stroke(NuviPalette.lavender, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear, value: progress)
        }
    }
}
