import Foundation

/// A bounded stack of whole-state snapshots, one entry per user action.
///
/// **Snapshots, not inverse commands.** Every mutation in this app is a method on
/// `ProjectState` — append, remove, replace, re-record a sweep, install a
/// calibration — and there are twenty-odd of them. Writing an inverse for each
/// means twenty-odd opportunities to get one wrong, and a wrong inverse is worse
/// than no undo at all: it silently produces a state the user never had. A
/// `ProjectState` is also cheap to copy: a handful of arrays of 16-byte points,
/// so a heavily digitised chart is a few hundred kilobytes and a session's worth
/// of steps is a few megabytes. `capacity` bounds that.
///
/// **One action, one entry.** `commit(before:label:now:)` is called *after* the
/// mutation and keeps the previous state only if the state actually changed.
/// That is what makes a no-op free — an eraser stroke that touched nothing, a
/// re-digitise that found the same points — instead of an entry that undoes to
/// where it already is, which reads to the user as a broken button.
///
/// Generic over the state so the tests can drive it with something small. The
/// app instantiates it at `ProjectState`.
public struct UndoHistory<State: Equatable> {

    /// One recorded action: what it was called, and the state to go back to.
    public struct Entry: Equatable {
        /// Name of the action that *produced* the state now in effect. Read as
        /// the verb in the menu: this is what 「撤销 …」 will take back.
        public let label: String
        /// The state as it stood before that action ran.
        public let state: State

        public init(label: String, state: State) {
            self.label = label
            self.state = state
        }
    }

    private var past: [Entry] = []
    private var future: [Entry] = []

    /// How many actions back the user can go.
    ///
    /// Bounded because the snapshots are whole states: without a cap, a long
    /// session on a densely digitised chart would hold every point of every
    /// intermediate state alive at once. Each entry is only ever one array copy
    /// on top of its neighbour, so 30 is roomy at a size that cannot grow.
    public let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = max(1, capacity)
    }

    // MARK: - Recording

    /// Records one completed action.
    ///
    /// Called after the mutation with the state from before it, so the two can be
    /// compared: a mutation that left the state as it found it records nothing
    /// and returns false. Recording also **clears the redo stack**, which is the
    /// standard bargain — once the user does something new, the branch they had
    /// rewinded away from is gone, and keeping it would let 「重做」 resurrect a
    /// state that never followed from what is on screen.
    ///
    /// - Returns: whether an entry was kept.
    @discardableResult
    public mutating func commit(before: State, label: String, now: State) -> Bool {
        guard before != now else { return false }
        past.append(Entry(label: label, state: before))
        if past.count > capacity { past.removeFirst(past.count - capacity) }
        future.removeAll()
        return true
    }

    // MARK: - Traversal

    /// Steps back one action and returns the state to restore, or nil at the
    /// bottom of the stack.
    ///
    /// The caller passes what is on screen so it can be pushed onto the redo
    /// stack: the entry remembers the label of the action being taken back, so
    /// 「重做」 offers exactly that action's name again.
    @discardableResult
    public mutating func undo(now: State) -> Entry? {
        guard let entry = past.popLast() else { return nil }
        future.append(Entry(label: entry.label, state: now))
        return entry
    }

    /// Steps forward one action and returns the state to restore, or nil when
    /// nothing has been taken back.
    @discardableResult
    public mutating func redo(now: State) -> Entry? {
        guard let entry = future.popLast() else { return nil }
        past.append(Entry(label: entry.label, state: now))
        return entry
    }

    // MARK: - Reading

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    /// How many actions can still be taken back.
    public var depth: Int { past.count }
    /// How many actions can still be reapplied.
    public var redoDepth: Int { future.count }

    /// What 「撤销」 would take back, for the menu to name the action.
    public var undoLabel: String? { past.last?.label }
    /// What 「重做」 would reapply.
    public var redoLabel: String? { future.last?.label }

    // MARK: - Clearing

    /// Forgets everything. Used when the image is replaced: the snapshots belong
    /// to a chart that is no longer on screen, and restoring one would put points
    /// back onto a different picture.
    public mutating func reset() {
        past.removeAll()
        future.removeAll()
    }
}
