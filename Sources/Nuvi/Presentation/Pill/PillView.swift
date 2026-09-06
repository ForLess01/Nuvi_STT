import SwiftUI
import Translation

/// The SuperWhisper-style pill: a dark glass capsule with the circular ferrofluid
/// visualizer on the left and the live transcript (or state) on the right.
struct PillView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var translation: TranslationCoordinator
    @ObservedObject var ferrofluid: FerrofluidSettingsStore = .shared
    @ObservedObject private var localization = LocalizationStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ferrofluidCircle
            label
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(background)
        .shadow(color: isError ? NuviPalette.lavender.opacity(0.32) : .clear, radius: isError ? 16 : 0, y: 0)
        .fixedSize()
        .translationTask(translation.configuration) { session in
            await translation.perform(using: session)
        }
    }

    private var ferrofluidCircle: some View {
        ZStack {
            // Pure white circle chamber — no black borders, no dark outer rim
            Circle()
                .fill(NuviPalette.softWhite)
                .shadow(color: NuviPalette.charcoal.opacity(0.18), radius: 4, y: 1.5)

            // Spectrum Ferrofluid visualizer (active state)
            FerrofluidView(
                level: controller.level,
                spectrum: controller.spectrum,
                settings: ferrofluid.settings,
                paused: isCompleted
            )
            .clipShape(Circle())
            .opacity(isCompleted ? 0 : 0.98)

            // Completion state: clean solid checkmark inside the exact same centered white circle
            CompletionCheckmark(isActive: isCompleted)
                .padding(10)
                .opacity(isCompleted ? 1 : 0)
        }
        .frame(width: 42, height: 42)
        .animation(completionTransition, value: isCompleted)
    }

    private var label: some View {
        Text(displayText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(labelColor)
            .lineLimit(2)
            .frame(maxWidth: 320, alignment: .leading)
            .contentTransition(.opacity)
            .animation(completionTransition, value: isCompleted)
    }

    private var displayText: String {
        PillDisplayText.resolve(
            state: controller.state,
            transcript: controller.transcript,
            stateLabel: stateLabel,
            isLiveSession: controller.isLiveSession
        )
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            // Layer 1: Wide ethereal mist plume / brush wash (diffused horizontal falloff)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isError
                            ? [NuviPalette.lavender.opacity(0.35), NuviPalette.charcoal.opacity(0.55), NuviPalette.charcoal.opacity(0.20)]
                            : [NuviPalette.charcoal.opacity(0.72), NuviPalette.charcoal.opacity(0.58), NuviPalette.charcoal.opacity(0.22)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .padding(.horizontal, -14)
                .padding(.vertical, -6)
                .blur(radius: 12)

            // Layer 2: Frosted glass material with feathered contour (zero hard edges)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.85)
                .padding(.horizontal, -4)
                .padding(.vertical, -2)
                .blur(radius: 3)

            // Layer 3: Main body mist (dark smoky core for solid contrast of text & spectrum)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: backgroundGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(.horizontal, -2)
                .padding(.vertical, -1)
                .blur(radius: 4)

            // Layer 4: Soft horizontal vapor sheen (subtle organic mist gleam, no stroke)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            NuviPalette.softWhite.opacity(0.12),
                            NuviPalette.softWhite.opacity(0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(2)
                .blur(radius: 3)
                .blendMode(.screen)
        }
        .compositingGroup()
    }

    private var backgroundGradientColors: [Color] {
        if isError {
            return [NuviPalette.lavender.opacity(0.48), NuviPalette.charcoal.opacity(0.82), NuviPalette.charcoal.opacity(0.70)]
        }
        return [NuviPalette.charcoal.opacity(0.88), NuviPalette.charcoal.opacity(0.80), NuviPalette.charcoal.opacity(0.68)]
    }

    private var labelColor: Color {
        if isCompleted { return NuviPalette.lavender }
        if controller.isLiveSession { return NuviPalette.softWhite.opacity(0.92) }
        return isError
            ? NuviPalette.softWhite.opacity(0.96)
            : NuviPalette.softWhite.opacity(controller.transcript.isEmpty ? 0.55 : 0.92)
    }

    private var isCompleted: Bool {
        controller.state == .inserted || controller.state == .copied
    }

    private var completionTransition: Animation {
        if reduceMotion { return .easeOut(duration: 0.08) }
        return .timingCurve(0.16, 0.84, 0.32, 1, duration: 0.16)
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: return "Nuvi"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .inserted: return tr("Inserted", "Insertado")
        case .copied: return tr("Copied", "Copiado")
        case .notice(let message): return message
        case .error(let message): return message
        }
    }
}

enum PillDisplayText {
    static func resolve(
        state: DictationState,
        transcript: String,
        stateLabel: String,
        isLiveSession: Bool = false
    ) -> String {
        // Completion is semantic UI, not transcription preview. Published
        // state and transcript changes can render on separate SwiftUI passes,
        // so completion must win even if the previous transcript is still
        // observable for one frame.
        switch state {
        case .inserted, .copied:
            return stateLabel
        case .listening where isLiveSession:
            return "LIVE"
        case .transcribing where isLiveSession:
            return "LIVE"
        default:
            return transcript.isEmpty ? stateLabel : transcript
        }
    }
}

private struct CompletionCheckmark: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    // Solid dark charcoal: clean, high-contrast, flat design without metallic sheen
    private let color = NuviPalette.charcoal

    var body: some View {
        GeometryReader { proxy in
            CheckmarkPath()
                .trim(from: 0, to: progress)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
                )
        }
        .onAppear { updateProgress(for: isActive) }
        .onChange(of: isActive) { _, active in updateProgress(for: active) }
    }

    private func updateProgress(for active: Bool) {
        guard !reduceMotion else {
            progress = active ? 1 : 0
            return
        }

        withAnimation(.timingCurve(0.16, 0.84, 0.32, 1, duration: 0.18)) {
            progress = active ? 1 : 0
        }
    }
}

private struct CheckmarkPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.22, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.width * 0.44, y: rect.height * 0.74))
        path.addLine(to: CGPoint(x: rect.width * 0.80, y: rect.height * 0.30))
        return path
    }
}
