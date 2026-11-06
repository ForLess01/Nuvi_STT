import Foundation
import Combine

/// Persisted, user-editable shortcuts. Rejected edits never reach UserDefaults.
@MainActor
public final class ShortcutsStore: ObservableObject {
    public static let shared = ShortcutsStore()

    public enum Action: CaseIterable { case toggle, cycleMode, pushToTalk }
    public enum Issue: Equatable { case conflict, registrationFailed }
    @Published public private(set) var issue: Issue?
    /// Changes only after accepted edits, not when reporting registration errors.
    let changes = PassthroughSubject<Void, Never>()
    private var registrationIssue: Issue?
    private let defaults: UserDefaults
    private var storedToggle: KeyCombo
    private var storedCycle: KeyCombo
    private var storedPTT: KeyCombo?

    public var toggle: KeyCombo {
        get { storedToggle }
        set { update(.toggle, to: newValue) }
    }
    public var cycleMode: KeyCombo {
        get { storedCycle }
        set { update(.cycleMode, to: newValue) }
    }
    public var pushToTalk: KeyCombo? {
        get { storedPTT }
        set { update(.pushToTalk, to: newValue) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedToggle = Self.load("nuvi.sc.toggle", defaults: defaults) ?? .toggleDefault
        storedCycle = Self.load("nuvi.sc.cycle", defaults: defaults) ?? .cycleDefault
        storedPTT = Self.load("nuvi.sc.ptt", defaults: defaults)
    }

    func combo(for action: Action) -> KeyCombo? {
        switch action {
        case .toggle: return toggle
        case .cycleMode: return cycleMode
        case .pushToTalk: return pushToTalk
        }
    }

    /// Compare what the native backend registers, never the display label.
    static func conflicts(_ lhs: KeyCombo, _ rhs: KeyCombo) -> Bool {
        guard lhs.keyCode == rhs.keyCode else { return false }
        return lhs.isModifierOnly
            ? lhs.cocoaModifiers == rhs.cocoaModifiers
            : lhs.carbonModifiers == rhs.carbonModifiers
    }

    @discardableResult
    public func update(_ action: Action, to combo: KeyCombo?) -> Bool {
        guard combo != nil || action == .pushToTalk else { return false }
        let cancelShortcut = KeyCombo(keyCode: 53, cocoaModifiers: [], keyLabel: "esc")
        if let combo, Self.conflicts(combo, cancelShortcut) || Action.allCases.contains(where: {
            $0 != action && self.combo(for: $0).map { Self.conflicts(combo, $0) } == true
        }) {
            issue = .conflict
            return false
        }
        guard self.combo(for: action) != combo else { issue = registrationIssue; return true }
        objectWillChange.send()
        let key: String
        switch action {
        case .toggle: storedToggle = combo!; key = "nuvi.sc.toggle"
        case .cycleMode: storedCycle = combo!; key = "nuvi.sc.cycle"
        case .pushToTalk: storedPTT = combo; key = "nuvi.sc.ptt"
        }
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        issue = registrationIssue
        changes.send()
        return true
    }

    func reportRegistrationIssue(_ issue: Issue?) {
        registrationIssue = issue
        self.issue = issue
    }

    private static func load(_ key: String, defaults: UserDefaults) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
