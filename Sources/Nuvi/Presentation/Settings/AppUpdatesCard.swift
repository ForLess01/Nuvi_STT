import SwiftUI

struct AppUpdatesCard: View {
    @ObservedObject var updates: AppUpdateService
    @ObservedObject private var loc = LocalizationStore.shared

    private var statusText: String {
        if updates.isChecking { return tr("Checking for updates…", "Buscando actualizaciones…") }
        switch updates.status {
        case .idle: return tr("Checks automatically every 12 hours.", "Se comprueba automáticamente cada 12 horas.")
        case .current:
            return updates.availableRelease == nil
                ? tr("You're up to date.", "La aplicación está actualizada.")
                : tr("Open the release page to install the update.", "Abra la página de la versión para instalar la actualización.")
        case .failed: return tr("Couldn't check for updates. Try again when connected.", "No se pudo buscar actualizaciones. Inténtelo de nuevo cuando tenga conexión.")
        case .rateLimited: return tr("The update server is busy. Nuvi will retry later.", "El servidor de actualizaciones está ocupado. Nuvi lo intentará más tarde.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: tr("Updates", "Actualizaciones"))
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Installed version: \(updates.installedVersion)", "Versión instalada: \(updates.installedVersion)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let release = updates.availableRelease {
                        Label(tr("Nuvi \(release.version) is available", "Nuvi \(release.version) está disponible"), systemImage: "arrow.down.circle")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    HStack(spacing: 8) {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(tr("Checking for updates", "Buscando actualizaciones"))
                        }
                        Text(statusText).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let date = updates.lastChecked {
                        Text(tr("Last checked: ", "Última comprobación: ") + date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if updates.availableRelease != nil {
                        switch updates.notificationStatus {
                        case .denied:
                            Text(tr("Allow Nuvi in System Settings → Notifications for automatic alerts.",
                                    "Permita las notificaciones de Nuvi en Ajustes del Sistema → Notificaciones para recibir avisos automáticos."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        case .unavailable, .failed:
                            Text(tr("System alerts aren't available. Your update remains available here.",
                                    "Los avisos del sistema no están disponibles. La actualización sigue disponible aquí."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        case .idle, .delivered: EmptyView()
                        }
                    }
                    HStack(spacing: 12) {
                        Button(tr("Check for updates", "Buscar actualizaciones")) {
                            Task { await updates.check(force: true) }
                        }
                        .disabled(updates.isChecking)
                        .help(tr("Refresh update availability without installing anything.", "Compruebe las actualizaciones sin instalar nada."))
                        if let release = updates.availableRelease {
                            Link(tr("View update", "Ver actualización"), destination: release.url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }
}
