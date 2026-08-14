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
    @State private var activeLabelWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            ferrofluidCircle
            label
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(background)
        .overlay(border)
        .shadow(color: isError ? NuviPalette.lavender.opacity(0.28) : .clear, radius: isError ? 18 : 0, y: 0)
        .fixedSize()
        .translationTask(translation.configuration) { session in
            await translation.perform(using: session)
        }
    }

    private var ferrofluidCircle: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [NuviPalette.softWhite.opacity(0.16), NuviPalette.charcoal.opacity(0.72)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .overlay(
                    Circle()
                        .strokeBorder(NuviPalette.softWhite.opacity(0.12), lineWidth: 0.8)
                )

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [NuviPalette.softWhite, NuviPalette.softWhite.opacity(0.92), NuviPalette.charcoal.opacity(0.42)],
                                       center: .topLeading,
                                       startRadius: 2,
                                       endRadius: 28)
                    )
                FerrofluidView(
                    level: controller.level,
                    settings: ferrofluid.settings,
                    paused: isCompleted
                )
                .clipShape(Circle())
                .opacity(isCompleted ? 0 : 0.98)
                .scaleEffect(isCompleted && !reduceMotion ? 0.97 : 1)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                NuviPalette.lavender.opacity(0.42),
                                NuviPalette.charcoal
                            ],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: 28
                        )
                    )
                    .opacity(isCompleted ? 1 : 0)
                    .scaleEffect(isCompleted && !reduceMotion ? 1 : 0.96)

                CompletionCheckmark(isActive: isCompleted)
                    .padding(10)
                    .opacity(isCompleted ? 1 : 0)
                    .scaleEffect(isCompleted && !reduceMotion ? 1 : 0.96)
                Circle()
                    .strokeBorder(NuviPalette.charcoal.opacity(0.16), lineWidth: 1.2)
                Circle()
                    .strokeBorder(NuviPalette.softWhite.opacity(0.42), lineWidth: 0.7)
                    .blur(radius: 0.35)
                    .offset(x: -0.8, y: -0.8)
                Circle()
                    .fill(
                        LinearGradient(colors: [NuviPalette.softWhite.opacity(0.24), Color.clear],
                                       startPoint: .topLeading,
                                       endPoint: .center)
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .padding(4)
            .animation(completionTransition, value: isCompleted)
        }
        .frame(width: 48, height: 48)
        .shadow(color: NuviPalette.charcoal.opacity(0.28), radius: 7, y: 3)
    }

    private var label: some View {
        Text(displayText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(labelColor)
            .lineLimit(2)
            .frame(maxWidth: 320, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PillLabelWidthKey.self, value: proxy.size.width)
                }
            }
            // Keep the last active width through the short success state. The
            // AppKit host measures this view on every state change; retaining
            // the width prevents the entire pill from snapping narrower while
            // the ferrofluid crossfades into the checkmark.
            .frame(minWidth: isCompleted ? activeLabelWidth : nil, alignment: .leading)
            .contentTransition(.opacity)
            .animation(completionTransition, value: isCompleted)
            .onPreferenceChange(PillLabelWidthKey.self) { width in
                guard !isCompleted, width > 0 else { return }
                activeLabelWidth = width
            }
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
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(colors: backgroundGradientColors,
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(colors: [NuviPalette.softWhite.opacity(0.20), Color.clear, NuviPalette.charcoal.opacity(0.22)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .blendMode(.screen)

            Capsule(style: .continuous)
                .strokeBorder(NuviPalette.softWhite.opacity(isError ? 0.22 : 0.16), lineWidth: 0.8)
                .blur(radius: 0.35)
                .offset(x: -0.4, y: -0.7)

            Capsule(style: .continuous)
                .strokeBorder(NuviPalette.charcoal.opacity(0.34), lineWidth: 1.1)
                .blur(radius: 0.45)
                .offset(x: 0.5, y: 1.0)
        }
        .compositingGroup()
    }

    private var backgroundGradientColors: [Color] {
        if isError {
            return [NuviPalette.lavender.opacity(0.46), NuviPalette.charcoal.opacity(0.86), NuviPalette.charcoal.opacity(0.70)]
        }
        return [NuviPalette.softWhite.opacity(0.075), NuviPalette.charcoal.opacity(0.78), NuviPalette.charcoal.opacity(0.64)]
    }

    private var border: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                LinearGradient(colors: borderGradientColors,
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                lineWidth: isError ? 1.25 : 1
            )
    }

    private var borderGradientColors: [Color] {
        if isError { return [NuviPalette.softWhite.opacity(0.22), NuviPalette.lavender.opacity(0.56), NuviPalette.charcoal.opacity(0.20)] }
        return [NuviPalette.softWhite.opacity(0.22), NuviPalette.softWhite.opacity(0.07), NuviPalette.charcoal.opacity(0.28)]
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

private struct PillLabelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CompletionCheckmark: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    private let color = NuviPalette.lavender

    var body: some View {
        GeometryReader { proxy in
            let start = CGPoint(x: proxy.size.width * 0.16, y: proxy.size.height * 0.52)
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 3.2, height: 3.2)
                    .position(start)

                CheckmarkPath()
                    .trim(from: 0, to: progress)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                    )
            }
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
        path.move(to: CGPoint(x: rect.width * 0.16, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.76))
        path.addLine(to: CGPoint(x: rect.width * 0.84, y: rect.height * 0.27))
        return path
    }
}
