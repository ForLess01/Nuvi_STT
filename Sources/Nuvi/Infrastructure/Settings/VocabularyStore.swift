import Foundation
import Combine

/// A custom text replacement. Covers SpeechAnalyzer's lack of built-in custom
/// vocabulary: we fix known terms in post-processing before pasting.
public struct VocabularyRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var from: String
    public var to: String

    public init(id: UUID = UUID(), from: String = "", to: String = "") {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// Observable, persisted vocabulary. `apply` runs the replacements on a final
/// transcript right before injection.
@MainActor
public final class VocabularyStore: ObservableObject {
    public static let shared = VocabularyStore()

    @Published public var rules: [VocabularyRule] {
        didSet { save() }
    }

    private let key = "nuvi.vocabulary"
    private var pendingSave: DispatchWorkItem?

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([VocabularyRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
    }

    public func add() {
        rules.append(VocabularyRule())
    }

    public func delete(_ rule: VocabularyRule) {
        rules.removeAll { $0.id == rule.id }
    }

    /// Case-insensitive whole-word replacement for each non-empty rule.
    public func apply(to text: String) -> String {
        var result = text
        for rule in rules where !rule.from.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: rule.from)
            let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: rule.to)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    private func save() {
        pendingSave?.cancel()
        let rules = rules
        let key = key
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(rules) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
