import SwiftUI

/// The SuperWhisper-style pill: a dark glass capsule with the circular ferrofluid
/// visualizer on the left and the live transcript (or state) on the right.
struct PillView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var ferrofluid: FerrofluidSettingsStore = .shared

    var body: some View {
        HStack(spacing: 12) {
            ferrofluidCircle
            label
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(background)
        .overlay(border)
        .shadow(color: isError ? .red.opacity(0.24) : .clear, radius: isError ? 18 : 0, y: 0)
        .fixedSize()
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: controller.transcript)
        .animation(.easeInOut(duration: 0.2), value: controller.state)
    }

    private var ferrofluidCircle: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(colors: [Color.white.opacity(0.16), Color.black.opacity(0.72)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                )

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [Color.white, Color.white.opacity(0.92), Color.gray.opacity(0.42)],
                                       center: .topLeading,
                                       startRadius: 2,
                                       endRadius: 28)
                    )
                FerrofluidView(level: controller.level, settings: ferrofluid.settings)
                    .clipShape(Circle())
                    .opacity(0.98)
                Circle()
                    .strokeBorder(Color.black.opacity(0.16), lineWidth: 1.2)
                Circle()
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.7)
                    .blur(radius: 0.35)
                    .offset(x: -0.8, y: -0.8)
                Circle()
                    .fill(
                        LinearGradient(colors: [Color.white.opacity(0.24), Color.clear],
                                       startPoint: .topLeading,
                                       endPoint: .center)
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .padding(4)
        }
        .frame(width: 48, height: 48)
        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
    }

    @ViewBuilder
    private var label: some View {
        if !controller.transcript.isEmpty {
            Text(controller.transcript)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(labelColor)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .leading)
        } else {
            Text(stateLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(labelColor)
        }
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
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.clear, Color.black.opacity(0.22)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .blendMode(.screen)

            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(isError ? 0.22 : 0.16), lineWidth: 0.8)
                .blur(radius: 0.35)
                .offset(x: -0.4, y: -0.7)

            Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.34), lineWidth: 1.1)
                .blur(radius: 0.45)
                .offset(x: 0.5, y: 1.0)
        }
        .compositingGroup()
    }

    private var backgroundGradientColors: [Color] {
        if isError {
            return [Color.red.opacity(0.46), Color(red: 0.17, green: 0.02, blue: 0.03).opacity(0.74), Color.black.opacity(0.70)]
        }
        return [Color.white.opacity(0.075), Color(red: 0.055, green: 0.058, blue: 0.064).opacity(0.78), Color.black.opacity(0.64)]
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
        if isError { return [Color.white.opacity(0.22), Color.red.opacity(0.46), Color.black.opacity(0.20)] }
        return [Color.white.opacity(0.22), Color.white.opacity(0.07), Color.black.opacity(0.28)]
    }

    private var labelColor: Color {
        isError ? .white.opacity(0.96) : .white.opacity(controller.transcript.isEmpty ? 0.55 : 0.92)
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
        case .notice(let message): return message
        case .error(let message): return message
        }
    }
}
