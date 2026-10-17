import Foundation

/// Your categories and the tasks you've filed into them. Everyone starts with
/// `DefaultCategories`, so tasks are grouped from the first session; everything
/// you haven't filed is filed by `TaskClassifier`, learning from what you have.
///
/// Stored next to the timesheet in `categories.json` once you change anything.
/// Until then you get the defaults, including any improvements to them.
@MainActor
final class Categories: ObservableObject {
    struct Category: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var name: String
    }

    /// In creation order, which fixes each category's color and number key.
    @Published private(set) var list: [Category] = DefaultCategories.all.map { Category(id: $0.id, name: $0.name) }
    /// Task key → category ID (or `unsortedMark`), for tasks you filed yourself.
    @Published private(set) var assignments: [String: String] = [:]

    private let fileURL: URL
    private var classifier = TaskClassifier(assignments: [:])
    private var placements: [String: TaskClassifier.Placement?] = [:]

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("categories.json")
        load()
        relearn()
    }

    /// Filed as "Unsorted" on purpose, so it isn't guessed again.
    static let unsortedMark = "unsorted"

    func category(_ id: String?) -> Category? {
        list.first { $0.id == id }
    }

    /// Where a task belongs: filed by you, guessed, or nil (unsorted).
    func placement(for task: String) -> TaskClassifier.Placement? {
        let key = TimeLog.key(task)
        if assignments[key] == Self.unsortedMark { return nil }
        if let cached = placements[key] { return cached }
        let placement = classifier.classify(task)
        placements[key] = placement
        return placement
    }

    // MARK: - Editing

    /// Files a task (nil = unsorted, and stop guessing). Filing it where it was
    /// guessed confirms the guess.
    func assign(_ task: String, to id: String?) {
        assignments[TimeLog.key(task)] = id ?? Self.unsortedMark
        changed()
    }

    @discardableResult
    func create(named name: String) -> String? {
        let cleaned = TimeLog.clean(name)
        guard !cleaned.isEmpty else { return nil }
        if let existing = list.first(where: { TimeLog.key($0.name) == TimeLog.key(cleaned) }) { return existing.id }
        let category = Category(name: cleaned)
        list.append(category)
        changed()
        return category.id
    }

    func rename(_ id: String, to name: String) {
        let cleaned = TimeLog.clean(name)
        guard !cleaned.isEmpty, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = cleaned
        changed()
    }

    /// Removes a category; its tasks go back to unsorted.
    func delete(_ id: String) {
        list.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        changed()
    }

    /// Keeps a task's filing when it's renamed (or merged into another task).
    func taskRenamed(from old: String, to new: String) {
        let oldKey = TimeLog.key(old), newKey = TimeLog.key(new)
        guard oldKey != newKey, let id = assignments.removeValue(forKey: oldKey) else { return }
        if assignments[newKey] == nil { assignments[newKey] = id }
        changed()
    }

    // MARK: - Persistence

    private struct File: Codable {
        var version = 1
        var categories: [Category]
        var assignments: [String: String]
    }

    private func changed() {
        relearn()
        save()
    }

    private func relearn() {
        let known = Set(list.map(\.id))
        // A default you renamed keeps its examples; one you deleted loses them.
        classifier = TaskClassifier(assignments: assignments.filter { known.contains($0.value) },
                                    builtIn: DefaultCategories.examples.filter { known.contains($0.categoryID) })
        placements = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            list = file.categories
            assignments = file.assignments
        } catch {
            // Never overwrite a file we couldn't read — keep a copy aside first.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("categories-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            NSLog("Pomodoro: couldn't read categories (\(error)); backed up to \(backup.path)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(File(categories: list, assignments: assignments)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Pomodoro: couldn't save categories: \(error)")
        }
    }
}
