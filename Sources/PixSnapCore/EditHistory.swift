/// Snapshot-based undo and redo. Each `commit` is one undoable step.
public struct EditHistory<State: Equatable> {
    public private(set) var current: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(_ initial: State, limit: Int = 100) {
        self.current = initial
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Records `newState` as one step. Does nothing when the state didn't change.
    public mutating func commit(_ newState: State) {
        guard newState != current else { return }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
        current = newState
    }

    public mutating func apply(_ change: (inout State) -> Void) {
        var state = current
        change(&state)
        commit(state)
    }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }
}
