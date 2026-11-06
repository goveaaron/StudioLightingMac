import Foundation
import PrismCore

/// Snapshot-based undo history with time-window coalescing (slider drags become one step).
public struct UndoHistory: Sendable {
    public init() {}
    public struct Entry: Sendable {
        public var name: String
        public var document: ShowDocument
        public var coalesceKey: String?
        public var time: Double
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

    /// Records the state *before* a change.
    public mutating func record(before doc: ShowDocument, name: String, coalesceKey: String?, now: Double) {
        if let key = coalesceKey, var last = undoStack.last, last.coalesceKey == key, now - last.time < coalesceWindow {
            last.time = now
            undoStack[undoStack.count - 1] = last
            redoStack.removeAll()
            return
        }
        undoStack.append(Entry(name: name, document: UndoHistory.stripTransient(doc), coalesceKey: coalesceKey, time: now))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Returns the document to restore, pushing `current` onto the redo stack.
    public mutating func undo(current: ShowDocument) -> (name: String, document: ShowDocument)? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append(Entry(name: e.name, document: UndoHistory.stripTransient(current), coalesceKey: nil, time: 0))
        return (e.name, e.document)
    }

    public mutating func redo(current: ShowDocument) -> (name: String, document: ShowDocument)? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append(Entry(name: e.name, document: UndoHistory.stripTransient(current), coalesceKey: nil, time: 0))
        return (e.name, e.document)
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Fades, identify flashes and raw test values are never part of undo.
    public static func stripTransient(_ doc: ShowDocument) -> ShowDocument {
        var d = doc
        d.live.fades = [:]
        d.live.identify = [:]
        d.live.rawOverrides = []
        return d
    }
}
