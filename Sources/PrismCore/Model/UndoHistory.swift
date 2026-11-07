import Foundation

/// Snapshot-based undo history with time-window coalescing (slider drags become one step)
/// and actor attribution (`CommandOrigin` + timestamp) for the History timeline popover.
public struct UndoHistory: Sendable {
    public init() {}

    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var summary: String
        public var origin: CommandOrigin
        public var timestamp: Date
        /// The document state *before* this entry was applied.
        public var document: ShowDocument
        /// The document state *after* this entry was applied (if recorded).
        public var afterDocument: ShowDocument?
        public var coalesceKey: String?
        public var time: Double

        public init(
            id: UUID = UUID(),
            name: String,
            summary: String? = nil,
            origin: CommandOrigin = .ui,
            timestamp: Date = Date(),
            document: ShowDocument,
            afterDocument: ShowDocument? = nil,
            coalesceKey: String? = nil,
            time: Double
        ) {
            self.id = id
            self.name = name
            self.summary = summary ?? name
            self.origin = origin
            self.timestamp = timestamp
            self.document = document
            self.afterDocument = afterDocument
            self.coalesceKey = coalesceKey
            self.time = time
        }

        /// Human-readable attributed description (e.g. "Assistant: Warm up key light").
        public var attributedTitle: String {
            let detail = summary.isEmpty ? name : summary
            return "\(origin.displayName): \(detail)"
        }
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public var limit = 200
    /// Changes with the same coalesce key within this window merge into one undo step.
    public var coalesceWindow: Double = 1.2

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Chronological timeline (most recent first) of applied history entries for the UI popover.
    public var timeline: [Entry] { Array(undoStack.reversed()) }

    /// Records the state *before* (and optionally *after*) a change.
    public mutating func record(
        before doc: ShowDocument,
        after afterDoc: ShowDocument? = nil,
        name: String,
        summary: String? = nil,
        origin: CommandOrigin = .ui,
        coalesceKey: String?,
        now: Double,
        timestamp: Date = Date()
    ) {
        let strippedAfter = afterDoc.map { UndoHistory.stripTransient($0) }
        if let key = coalesceKey,
           var last = undoStack.last,
           last.coalesceKey == key,
           last.origin == origin,
           now - last.time < coalesceWindow {
            last.time = now
            last.timestamp = timestamp
            if let summary, !summary.isEmpty { last.summary = summary }
            if let strippedAfter { last.afterDocument = strippedAfter }
            undoStack[undoStack.count - 1] = last
            redoStack.removeAll()
            return
        }
        let entry = Entry(
            name: name,
            summary: summary ?? name,
            origin: origin,
            timestamp: timestamp,
            document: UndoHistory.stripTransient(doc),
            afterDocument: strippedAfter,
            coalesceKey: coalesceKey,
            time: now
        )
        undoStack.append(entry)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    /// Returns the document to restore, pushing `current` onto the redo stack.
    public mutating func undo(current: ShowDocument) -> (name: String, document: ShowDocument)? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append(
            Entry(
                id: e.id,
                name: e.name,
                summary: e.summary,
                origin: e.origin,
                timestamp: e.timestamp,
                document: UndoHistory.stripTransient(current),
                afterDocument: e.document,
                coalesceKey: nil,
                time: 0
            )
        )
        return (e.name, e.document)
    }

    public mutating func redo(current: ShowDocument) -> (name: String, document: ShowDocument)? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append(
            Entry(
                id: e.id,
                name: e.name,
                summary: e.summary,
                origin: e.origin,
                timestamp: e.timestamp,
                document: UndoHistory.stripTransient(current),
                afterDocument: e.document,
                coalesceKey: nil,
                time: 0
            )
        )
        return (e.name, e.document)
    }

    /// Reverts the show to the state right before `entryID` (or replays forward if `entryID` is in `redoStack`),
    /// preserving intermediate steps on the opposite stack so the user never loses history.
    public mutating func revertTo(entryID: UUID, current: ShowDocument) -> (name: String, document: ShowDocument)? {
        if let targetIdx = undoStack.firstIndex(where: { $0.id == entryID }) {
            var working = current
            var lastName = undoStack[targetIdx].name
            while undoStack.count > targetIdx {
                guard let step = undo(current: working) else { break }
                working = step.document
                lastName = step.name
            }
            return (lastName, working)
        }
        if let targetIdx = redoStack.firstIndex(where: { $0.id == entryID }) {
            var working = current
            var lastName = redoStack[targetIdx].name
            while redoStack.count > targetIdx {
                guard let step = redo(current: working) else { break }
                working = step.document
                lastName = step.name
            }
            return (lastName, working)
        }
        return nil
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Fades, identify flashes and raw test values are never part of undo.
    public static func stripTransient(_ doc: ShowDocument) -> ShowDocument {
        var d = doc
        d.live.fades = [:]
        d.live.effectFades = [:]
        d.live.musicFade = nil
        d.live.identify = [:]
        d.live.rawOverrides = []
        return d
    }
}
