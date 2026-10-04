import XCTest
@testable import GDCore

/// The undo stack is exercised with a bare `Int` rather than a `ProjectState`:
/// what it does is bookkeeping, and a state that is 0, 1, 2 … makes the sequence
/// of recorded versions readable at a glance.
final class UndoHistoryTests: XCTestCase {

    // MARK: - Recording

    func testCommitKeepsTheStateFromBeforeTheAction() {
        var history = UndoHistory<Int>()
        XCTAssertTrue(history.commit(before: 1, label: "加一", now: 2))

        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(history.undoLabel, "加一")
        XCTAssertEqual(history.undo(now: 2)?.state, 1, "撤销拿回的应当是动作之前的状态")
    }

    func testAnActionThatChangesNothingIsNotRecorded() {
        // The eraser sweeping empty space, a re-digitise that finds the same
        // points. An entry here would undo to where the user already is, which
        // reads as a button that does nothing.
        var history = UndoHistory<Int>()
        XCTAssertFalse(history.commit(before: 7, label: "擦除", now: 7))
        XCTAssertFalse(history.canUndo)
    }

    func testStepsAreTakenBackInReverseOrder() {
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "第一步", now: 1)
        history.commit(before: 1, label: "第二步", now: 2)
        history.commit(before: 2, label: "第三步", now: 3)

        XCTAssertEqual(history.undoLabel, "第三步")
        XCTAssertEqual(history.undo(now: 3)?.state, 2)
        XCTAssertEqual(history.undoLabel, "第二步")
        XCTAssertEqual(history.undo(now: 2)?.state, 1)
        XCTAssertEqual(history.undoLabel, "第一步")
        XCTAssertEqual(history.undo(now: 1)?.state, 0)
        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.undo(now: 0), "到底了还要撤,只能给 nil")
    }

    func testTheOldestEntriesFallOffOnceTheCapacityIsReached() {
        var history = UndoHistory<Int>(capacity: 3)
        for step in 0..<5 {
            history.commit(before: step, label: "第 \(step) 步", now: step + 1)
        }
        XCTAssertEqual(history.depth, 3, "只留住最近的三步")

        // The three that survive are the newest three: 4→3, 3→2, 2→1.
        XCTAssertEqual(history.undo(now: 5)?.state, 4)
        XCTAssertEqual(history.undo(now: 4)?.state, 3)
        XCTAssertEqual(history.undo(now: 3)?.state, 2)
        XCTAssertFalse(history.canUndo, "第 0 步和 第 1 步 已经被挤掉了")
    }

    func testCapacityOfZeroStillKeepsOneStep() {
        // A degenerate capacity would make the control permanently dead, which is
        // a worse answer than keeping a single step.
        var history = UndoHistory<Int>(capacity: 0)
        history.commit(before: 0, label: "唯一一步", now: 1)
        XCTAssertEqual(history.depth, 1)
        XCTAssertEqual(history.undo(now: 1)?.state, 0)
    }

    // MARK: - Redo

    func testRedoReappliesWhatUndoTookBack() {
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "取点", now: 5)

        let undone = history.undo(now: 5)
        XCTAssertEqual(undone?.state, 0)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redoLabel, "取点", "重做要报出被撤销的那个动作的名字")

        let redone = history.redo(now: 0)
        XCTAssertEqual(redone?.state, 5)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.canUndo, "重做之后还能再撤销")
    }

    func testASecondUndoRedoesInOrder() {
        // The redo stack is a stack, not a queue: two steps back must reapply
        // the earlier of the two first.
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "A", now: 1)
        history.commit(before: 1, label: "B", now: 2)
        history.undo(now: 2)
        history.undo(now: 1)

        XCTAssertEqual(history.redoLabel, "A")
        XCTAssertEqual(history.redo(now: 0)?.state, 1)
        XCTAssertEqual(history.redoLabel, "B")
        XCTAssertEqual(history.redo(now: 1)?.state, 2)
    }

    func testANewActionDiscardsTheRedoBranch() {
        // Once the user does something else, the branch they had rewound away
        // from never followed from what is on screen — offering to redo onto it
        // would produce a chart that was never built.
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "A", now: 1)
        history.commit(before: 1, label: "B", now: 2)
        history.undo(now: 2)
        XCTAssertTrue(history.canRedo)

        history.commit(before: 1, label: "C", now: 9)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undoLabel, "C")
    }

    func testRedoIsEmptyUntilSomethingIsUndone() {
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "A", now: 1)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo(now: 1))
        XCTAssertNil(history.redoLabel)
    }

    // MARK: - Bookkeeping

    func testUndoThenRedoReturnsToTheSameDepth() {
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "A", now: 1)
        history.commit(before: 1, label: "B", now: 2)
        XCTAssertEqual(history.depth, 2)

        history.undo(now: 2)
        XCTAssertEqual(history.depth, 1)
        XCTAssertEqual(history.redoDepth, 1)

        history.redo(now: 1)
        XCTAssertEqual(history.depth, 2)
        XCTAssertEqual(history.redoDepth, 0)
    }

    func testResetForgetsBothDirections() {
        var history = UndoHistory<Int>()
        history.commit(before: 0, label: "A", now: 1)
        history.commit(before: 1, label: "B", now: 2)
        history.undo(now: 2)

        history.reset()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.undoLabel)
    }

    // MARK: - The shape the app uses

    func testWholeProjectStatesSurviveTheRoundTrip() {
        // The generic is instantiated at `ProjectState` in the app, where the
        // state is a struct of arrays rather than an `Int`. Equality is the whole
        // basis of `commit` skipping no-ops, so it is worth one check that a real
        // state compares by value and not by identity.
        var state = ProjectState()
        state.gridSpacing = 8
        var history = UndoHistory<ProjectState>()

        var edited = state
        edited.gridSpacing = 20
        XCTAssertTrue(history.commit(before: state, label: "网格间距", now: edited))

        let restored = history.undo(now: edited)?.state
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored?.gridSpacing, 8)
    }
}
