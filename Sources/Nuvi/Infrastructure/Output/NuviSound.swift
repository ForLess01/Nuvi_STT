import AppKit

public enum SoundPreset: String, CaseIterable, Sendable {
    case pop
    case tink
    case funk
    case purr
    case glass
    case ping
    case bottle
    case hero
    case basso
    case blow
    case frog
    case morse
    case sosumi
    case submarine
    case cleanInsert
    case softConfirm
    case brightConfirm
    case glassTick
    case clipboardPunch
    case errorPunch
    case errorHeavy
    case roughAlert
    case deepDrop
    case liquidCancel
    case heroicAccent
    case minimalClick
    case rudeSnap
    case softRipple
    case quickLift
    case darkBloom

    public var displayName: String {
        switch self {
        case .pop: return "Pop"
        case .tink: return "Tink"
        case .funk: return "Funk"
        case .purr: return "Purr"
        case .glass: return "Glass"
        case .ping: return "Ping"
        case .bottle: return "Bottle"
        case .hero: return "Hero"
        case .basso: return "Basso"
        case .blow: return "Blow"
        case .frog: return "Frog"
        case .morse: return "Morse"
        case .sosumi: return "Sosumi"
        case .submarine: return "Submarine"
        case .cleanInsert: return "Clean Insert"
        case .softConfirm: return "Soft Confirm"
        case .brightConfirm: return "Bright Confirm"
        case .glassTick: return "Glass Tick"
        case .clipboardPunch: return "Clipboard Punch"
        case .errorPunch: return "Error Punch"
        case .errorHeavy: return "Error Heavy"
        case .roughAlert: return "Rough Alert"
        case .deepDrop: return "Deep Drop"
        case .liquidCancel: return "Liquid Cancel"
        case .heroicAccent: return "Heroic Accent"
        case .minimalClick: return "Minimal Click"
        case .rudeSnap: return "Rude Snap"
        case .softRipple: return "Soft Ripple"
        case .quickLift: return "Quick Lift"
        case .darkBloom: return "Dark Bloom"
        }
    }

    fileprivate var steps: [SoundStep] {
        switch self {
        case .pop: return [.init("Pop")]
        case .tink: return [.init("Tink")]
        case .funk: return [.init("Funk")]
        case .purr: return [.init("Purr")]
        case .glass: return [.init("Glass")]
        case .ping: return [.init("Ping")]
        case .bottle: return [.init("Bottle")]
        case .hero: return [.init("Hero")]
        case .basso: return [.init("Basso")]
        case .blow: return [.init("Blow")]
        case .frog: return [.init("Frog")]
        case .morse: return [.init("Morse")]
        case .sosumi: return [.init("Sosumi")]
        case .submarine: return [.init("Submarine")]
        case .cleanInsert: return [.init("Purr"), .init("Tink", after: 0.035)]
        case .softConfirm: return [.init("Pop"), .init("Tink", after: 0.04)]
        case .brightConfirm: return [.init("Ping"), .init("Glass", after: 0.035)]
        case .glassTick: return [.init("Glass"), .init("Tink", after: 0.04)]
        case .clipboardPunch: return [.init("Funk"), .init("Tink", after: 0.035)]
        case .errorPunch: return [.init("Funk"), .init("Ping", after: 0.045)]
        case .errorHeavy: return [.init("Basso"), .init("Funk", after: 0.055)]
        case .roughAlert: return [.init("Sosumi"), .init("Ping", after: 0.05)]
        case .deepDrop: return [.init("Submarine"), .init("Basso", after: 0.055)]
        case .liquidCancel: return [.init("Bottle"), .init("Purr", after: 0.055)]
        case .heroicAccent: return [.init("Hero"), .init("Ping", after: 0.055)]
        case .minimalClick: return [.init("Tink"), .init("Ping", after: 0.03)]
        case .rudeSnap: return [.init("Funk"), .init("Sosumi", after: 0.05)]
        case .softRipple: return [.init("Purr"), .init("Glass", after: 0.05)]
        case .quickLift: return [.init("Pop"), .init("Purr", after: 0.04)]
        case .darkBloom: return [.init("Submarine"), .init("Funk", after: 0.06)]
        }
    }
}

public enum SoundEvent: String, CaseIterable, Sendable {
    case start
    case stop
    case inserted
    case copied
    case cancel
    case error

    public var title: String {
        switch self {
        case .start: return "Start recording"
        case .stop: return "Stop recording"
        case .inserted: return "Direct insertion"
        case .copied: return "Copied to clipboard"
        case .cancel: return "Cancel"
        case .error: return "Error"
        }
    }

    public var subtitle: String {
        switch self {
        case .start: return "When listening begins"
        case .stop: return "When recording stops"
        case .inserted: return "When text is inserted into an app"
        case .copied: return "When text falls back to clipboard"
        case .cancel: return "When dictation is discarded"
        case .error: return "When Nuvi cannot complete an action"
        }
    }

    public var defaultPreset: SoundPreset {
        switch self {
        case .start: return .pop
        case .stop: return .tink
        case .inserted: return .cleanInsert
        case .copied: return .funk
        case .cancel: return .bottle
        case .error: return .errorPunch
        }
    }
}

private struct SoundStep: Sendable {
    let name: String
    let delay: TimeInterval

    init(_ name: String, after delay: TimeInterval = 0) {
        self.name = name
        self.delay = delay
    }
}

/// Lightweight sound feedback using built-in system sounds. Gated by a setting.
@MainActor
public enum NuviSound {
    public static func start() { play(.start) }
    public static func stop() { play(.stop) }
    public static func pasted() { play(.inserted) }
    public static func copied() { play(.copied) }
    public static func cancel() { play(.cancel) }
    public static func error() { play(.error) }

    public static func preview(_ preset: SoundPreset) {
        play(preset)
    }

    private static func play(_ event: SoundEvent) {
        play(SettingsStore.shared.soundPreset(for: event))
    }

    private static func play(_ preset: SoundPreset) {
        guard SettingsStore.shared.soundEffects else { return }

        for step in preset.steps {
            if step.delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                    playNow(step.name)
                }
            } else {
                playNow(step.name)
            }
        }
    }

    private static func playNow(_ name: String) {
        guard SettingsStore.shared.soundEffects else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
