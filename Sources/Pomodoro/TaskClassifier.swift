import Foundation
import NaturalLanguage

/// Files a task name into a category. Works out of the box from built-in
/// example phrases, and learns from every task you file yourself — yours
/// always win. Runs entirely on-device.
///
/// 1. A task you filed stays where you put it.
/// 2. Words: a word votes for a category if every example containing it is in
///    that category ("gift", "cold", "demo"). Words shared across categories
///    ("call") cancel out on their own. ALL-CAPS words (GAL, GDPR) count double —
///    they're usually a customer or project name. A tie stays unsorted.
/// 3. Meaning: otherwise, the closest example by sentence embedding, if it's
///    close enough. Anything else stays unsorted rather than guessed badly.
///
/// Steps 2–3 run on the tasks you've filed first, then on the built-in examples.
struct TaskClassifier {
    struct Placement: Equatable {
        var categoryID: String
        /// Filed by the classifier rather than by you.
        var isGuess: Bool
    }

    /// Distance (0–2, as `NLEmbedding.distance` reports it) under which the
    /// nearest example is trusted.
    static let embeddingThreshold = 0.8

    private let labelsByKey: [String: String]
    private let yours: Examples
    private let builtIn: Examples

    /// `assignments`: task key → category ID, as filed by you.
    /// `builtIn`: example phrase → category ID, used when yours don't decide.
    init(assignments: [String: String], builtIn: [(text: String, categoryID: String)] = [],
         embeddings: EmbeddingCache? = .shared) {
        labelsByKey = assignments
        yours = Examples(assignments.map { ($0.key, $0.value) }, embeddings: embeddings)
        self.builtIn = Examples(builtIn, embeddings: embeddings)
    }

    func classify(_ task: String) -> Placement? {
        let key = TimeLog.key(task)
        if let id = labelsByKey[key] { return Placement(categoryID: id, isGuess: false) }
        guard key != TimeLog.key(TimeLog.untitled) else { return nil }
        let id = yours.byWords(task) ?? yours.byMeaning(task) ?? builtIn.byWords(task) ?? builtIn.byMeaning(task)
        return id.map { Placement(categoryID: $0, isGuess: true) }
    }

    /// One set of labelled examples: yours, or the built-in ones.
    private struct Examples {
        let labels: [(text: String, categoryID: String)]
        /// Word → the categories of examples that contain it.
        let wordCategories: [String: Set<String>]
        let embeddings: EmbeddingCache?

        init(_ labels: [(text: String, categoryID: String)], embeddings: EmbeddingCache?) {
            self.labels = labels.sorted { $0.text < $1.text }
            var words: [String: Set<String>] = [:]
            for label in labels {
                for word in TaskClassifier.words(in: label.text) { words[word.text, default: []].insert(label.categoryID) }
            }
            wordCategories = words
            self.embeddings = embeddings
        }

        func byWords(_ task: String) -> String? {
            var votes: [String: Int] = [:]
            for word in TaskClassifier.words(in: task) {
                guard let categories = wordCategories[word.text], categories.count == 1 else { continue }
                votes[categories.first!, default: 0] += word.isAllCaps ? 2 : 1
            }
            let ranked = votes.sorted { $0.value > $1.value }
            guard let top = ranked.first else { return nil }
            if ranked.count > 1 && ranked[1].value == top.value { return nil }
            return top.key
        }

        func byMeaning(_ task: String) -> String? {
            guard !labels.isEmpty, let embeddings, let query = embeddings.vector(TaskClassifier.content(of: task)) else { return nil }
            var best: (id: String, distance: Double)?
            for label in labels {
                guard let vector = embeddings.vector(TaskClassifier.content(of: label.text)) else { continue }
                let distance = EmbeddingCache.distance(query, vector)
                if distance < (best?.distance ?? .infinity) { best = (label.categoryID, distance) }
            }
            guard let best, best.distance <= TaskClassifier.embeddingThreshold else { return nil }
            return best.id
        }
    }

    // MARK: - Text

    struct Word: Hashable {
        var text: String
        var isAllCaps: Bool
    }

    /// Generic words that say nothing about what kind of work it was.
    static let stopWords: Set<String> = [
        "and", "the", "for", "with", "from", "into", "about", "out", "off", "over", "via", "per",
        "call", "meet", "meeting", "chat", "sync", "prep", "follow", "misc", "etc", "odd", "stuff",
        "task", "work", "quick", "more", "new", "some", "other", "general", "time",
    ]

    /// Lowercased, lightly stemmed content words ("Gifting prospects" → gift, prospect).
    static func words(in text: String) -> [Word] {
        text.split { !$0.isLetter && !$0.isNumber }.compactMap { raw in
            let original = String(raw)
            let isAllCaps = original.count >= 2 && original == original.uppercased() && original.contains { $0.isLetter }
            let lower = stem(original.lowercased())
            guard lower.count >= 3 || isAllCaps, !stopWords.contains(lower) else { return nil }
            return Word(text: lower, isAllCaps: isAllCaps)
        }
    }

    private static func stem(_ word: String) -> String {
        if word.count > 5 && word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// The name without generic words, so "Call: interview" and "Call: demo"
    /// aren't judged alike just for starting with "Call".
    static func content(of text: String) -> String {
        let kept = text.split { !$0.isLetter && !$0.isNumber }
            .filter { !stopWords.contains(stem($0.lowercased())) }
            .joined(separator: " ")
            .lowercased()
        return kept.isEmpty ? text.lowercased() : kept
    }
}

/// Sentence vectors from macOS's built-in English embedding, cached by text.
final class EmbeddingCache: @unchecked Sendable {
    static let shared = EmbeddingCache()

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var vectors: [String: [Double]?] = [:]
    private let lock = NSLock()

    func vector(_ text: String) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        if let cached = vectors[text] { return cached }
        let vector = embedding?.vector(for: text)
        vectors[text] = vector
        return vector
    }

    /// Euclidean distance between the unit vectors — the same 0–2 scale as
    /// `NLEmbedding.distance(between:and:)`.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices where i < b.count {
            dot += a[i] * b[i]; normA += a[i] * a[i]; normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return .infinity }
        let cosine = dot / (normA.squareRoot() * normB.squareRoot())
        return (2 * max(0, 1 - cosine)).squareRoot()
    }
}
