import XCTest
@testable import GDCore

/// 点重排: the ring brush that renumbers points in the order it passes over them.
///
/// The two failure modes worth pinning are the ones a hand-drawn gesture invites.
/// A fast drag must not skip whole stretches of a curve, because that is exactly
/// what a person does when the curve is long; and a catch must be ordered by
/// where the brush was going, not by which point happens to sit nearest the ring,
/// because those two orders differ all the time and only one of them is right.
final class SweepReorderTests: XCTestCase {

    private let black = RGB8(r: 0, g: 0, b: 0)

    // MARK: - The stroke itself

    /// The headline test. A 200px drag delivered as a single event, over a row of
    /// points, with a ring that only covers 36px of it.
    ///
    /// Without the path resampling this catches the points near the two ends and
    /// nothing in between — the ring was never sampled in the middle, so the
    /// middle was never looked at. That is the bug the whole design is built
    /// around, and this is the assertion that fails if the resampling goes away.
    func testASingleFastDragStillCatchesEveryPointItPassedOver() {
        let points = (0...200).map { PixelPoint(x: Double($0), y: 100) }
        var brush = SweepReorder(pointCount: points.count)

        brush.sweep(points: points,
                    from: PixelPoint(x: 0, y: 100),
                    to: PixelPoint(x: 200, y: 100),
                    radius: 18)

        XCTAssertEqual(brush.swept, points.count,
                       "一次拖拽跨过全部点时必须一个不漏")
        XCTAssertEqual(brush.resolve(points).map(\.x), points.map(\.x),
                       "沿一条直线扫过,顺序应与位置一致")
    }

    /// A catch is ordered by the brush's direction of travel, not by distance
    /// from the ring's centre.
    ///
    /// The two points are chosen so the two rules disagree: the far one (-8) is
    /// what the brush reaches first travelling in +x, while the near one (+4) is
    /// what "nearest the centre" would pick. Only projection gets this right.
    func testACatchIsOrderedByTravelNotByDistanceFromTheCentre() {
        let farBehind = PixelPoint(x: -8, y: 0)
        let nearAhead = PixelPoint(x: 4, y: 0)
        let points = [nearAhead, farBehind]      // stored nearest-first on purpose
        var brush = SweepReorder(pointCount: points.count)

        brush.capture(points: points,
                      around: PixelPoint(x: 0, y: 0),
                      radius: 10,
                      direction: (dx: 1, dy: 0))

        XCTAssertEqual(brush.sequence, [1, 0],
                       "沿 +x 前进时应先碰到 -8 处的点,而不是更近的 +4")
    }

    /// A press that has not moved has no direction to project onto, so it falls
    /// back to distance. Documented rather than accidental: it makes a click a
    /// way to fill a gap, but not a way to express an order.
    func testAPressWithNoMovementFallsBackToDistance() {
        let near = PixelPoint(x: 3, y: 0)
        let far = PixelPoint(x: 8, y: 0)
        var brush = SweepReorder(pointCount: 2)

        brush.capture(points: [far, near], around: PixelPoint(x: 0, y: 0),
                      radius: 10, direction: nil)

        XCTAssertEqual(brush.sequence, [1, 0], "没有方向时按离圆心近的在前")
    }

    /// A zero-length direction carries no more information than none at all, and
    /// normalising it would divide by zero.
    func testADegenerateDirectionIsTreatedAsNoDirection() {
        let near = PixelPoint(x: 3, y: 0)
        let far = PixelPoint(x: 8, y: 0)
        var brush = SweepReorder(pointCount: 2)

        brush.capture(points: [far, near], around: PixelPoint(x: 0, y: 0),
                      radius: 10, direction: (dx: 0, dy: 0))

        XCTAssertEqual(brush.sequence, [1, 0])
        XCTAssertEqual(brush.sequence.count, 2, "退化方向不能产生重复或丢失")
    }

    /// Going back over ground already swept leaves it alone, which is what lets a
    /// sweep be done in several passes.
    func testPointsAlreadyNumberedAreNeverRenumbered() {
        let points = (0...20).map { PixelPoint(x: Double($0) * 10, y: 0) }
        var brush = SweepReorder(pointCount: points.count)

        brush.sweep(points: points, from: PixelPoint(x: 0, y: 0),
                    to: PixelPoint(x: 200, y: 0), radius: 18)
        let firstPass = brush.sequence
        XCTAssertFalse(firstPass.isEmpty)

        brush.sweep(points: points, from: PixelPoint(x: 0, y: 0),
                    to: PixelPoint(x: 200, y: 0), radius: 18)
        XCTAssertEqual(brush.sequence, firstPass, "重复扫过不产生新的编号")

        brush.capture(points: points, around: PixelPoint(x: 200, y: 0),
                      radius: 30, direction: nil)
        XCTAssertEqual(brush.sequence, firstPass)
        XCTAssertEqual(Set(brush.sequence).count, brush.sequence.count, "不能有重复下标")
    }

    func testEveryPointNumberedReportsComplete() {
        let points = (0...4).map { PixelPoint(x: Double($0), y: 0) }
        var brush = SweepReorder(pointCount: points.count)
        XCTAssertFalse(brush.isComplete)
        brush.sweep(points: points, from: PixelPoint(x: 0, y: 0),
                    to: PixelPoint(x: 4, y: 0), radius: 2)
        XCTAssertEqual(brush.remaining, 0)
        XCTAssertTrue(brush.isComplete)
    }

    // MARK: - A curve that a plain sort cannot fix

    /// The reason the tool exists: a curve with several points on the same column.
    ///
    /// A left half circle — x falls from 300 to 200 and climbs back to 300 — taken
    /// column by column the way 区域取点 takes it. Sorting by x cannot recover the
    /// arc, because the column that holds the leftmost point holds two points and
    /// the order between them is not in the coordinates at all. Sweeping the arc
    /// does recover it.
    func testSweepingRecoversAnArcThatSortingByXCannot() {
        let centre = PixelPoint(x: 300, y: 300)
        let radius = 100.0
        // 90°…270°, i.e. the left half, which is not single-valued in x.
        let arc = stride(from: 90.0, through: 270.0, by: 5.0).map { degrees -> PixelPoint in
            let a = degrees * .pi / 180
            return PixelPoint(x: centre.x + radius * cos(a), y: centre.y + radius * sin(a))
        }
        XCTAssertEqual(arc.count, 37)

        // Extraction order: a column-major scan, which is what the arc looks like
        // when it comes out of 区域取点 — the same x appears twice, far apart.
        let extracted = arc.enumerated()
            .sorted { ($0.element.x, $0.element.y) < ($1.element.x, $1.element.y) }
            .map(\.element)

        var brush = SweepReorder(pointCount: extracted.count)
        for (a, b) in zip(arc, arc.dropFirst()) {
            brush.sweep(points: extracted, from: a, to: b, radius: 20)
        }

        XCTAssertEqual(brush.swept, arc.count, "弧线上每个点都应被扫到")
        let resolved = brush.resolve(extracted)
        XCTAssertEqual(resolved, arc, "扫过之后应还原成弧线的真实顺序")

        // ...and the point of it all: no sort of the points can get there.
        XCTAssertNotEqual(PointOrder.ascendingX.apply(to: extracted), arc,
                          "若按 X 排序就能还原,这个工具就没有存在的必要")
    }

    // MARK: - Resolving

    func testUnsweptPointsComeLastInTheirOriginalOrder() {
        let points = [
            PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 0),
            PixelPoint(x: 2, y: 0), PixelPoint(x: 3, y: 0),
        ]
        let (ordered, swept) = SweepReorder.resolve(points, sequence: [2, 0])
        XCTAssertEqual(ordered, [points[2], points[0], points[1], points[3]])
        XCTAssertEqual(swept, 2, "前缀长度就是已扫过的点数")
    }

    /// A stored sequence comes off disk, so it is data, not a guarantee.
    func testResolvingToleratesOutOfRangeAndRepeatedIndices() {
        let points = [
            PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 0), PixelPoint(x: 2, y: 0),
        ]
        let (ordered, swept) = SweepReorder.resolve(points, sequence: [7, 0, 0, -1, 2])
        XCTAssertEqual(ordered, [points[0], points[2], points[1]])
        XCTAssertEqual(swept, 2)
        XCTAssertEqual(Set(ordered).count, ordered.count, "不能重复,也不能丢点")
    }

    func testNoSequenceLeavesThePointsAlone() {
        let points = (0...3).map { PixelPoint(x: Double($0), y: 0) }
        let (ordered, swept) = SweepReorder.resolve(points, sequence: [])
        XCTAssertEqual(ordered, points)
        XCTAssertEqual(swept, 0)
    }

    // MARK: - Model integration

    private func stateWithCurve(pointCount: Int = 4) -> (ProjectState, UUID) {
        var state = ProjectState()
        state.addLine(name: "c", color: black)
        let id = state.activeLineID!
        state.append(points: (0..<pointCount).map { PixelPoint(x: Double($0), y: 0) },
                     usingDefaultColor: black)
        return (state, id)
    }

    func testRecordingASweepIsWhatMakesItShow() {
        var (state, id) = stateWithCurve()
        XCTAssertEqual(state.lines[0].order, .extraction)
        XCTAssertNil(state.lines[0].sweptOrder)

        state.recordSweep([2, 0, 1], for: id)
        // The mode switches itself: sweeping *is* the act of choosing this order,
        // and needing a second click before anything moves would make the gesture
        // look like it did nothing.
        XCTAssertEqual(state.lines[0].order, .swept)
        XCTAssertEqual(state.lines[0].orderedPoints.map(\.x), [2, 0, 1, 3])
        XCTAssertEqual(state.lines[0].orderedPointsAndSweptCount.sweptCount, 3)
    }

    func testSwitchingBackToExtractionRestoresTheOriginalOrder() {
        var (state, id) = stateWithCurve()
        state.recordSweep([2, 0, 1], for: id)
        state.setOrder(.extraction, for: id)
        XCTAssertEqual(state.lines[0].orderedPoints.map(\.x), [0, 1, 2, 3])
        // ...without losing the sweep, so switching back and forth costs nothing.
        XCTAssertEqual(state.lines[0].sweptOrder, [2, 0, 1])
        state.setOrder(.swept, for: id)
        XCTAssertEqual(state.lines[0].orderedPoints.map(\.x), [2, 0, 1, 3])
    }

    /// The invalidation rule. A sweep is stored as indices, so a point inserted or
    /// removed makes every index after it mean a different point — silently
    /// rearranging the curve on the next redraw.
    func testChangingThePointsDropsTheSweepAndItsMode() {
        func swept() -> (ProjectState, UUID) {
            var (state, id) = stateWithCurve()
            state.recordSweep([2, 0, 1], for: id)
            return (state, id)
        }

        var appended = swept()
        appended.0.append(points: [PixelPoint(x: 9, y: 0)], usingDefaultColor: black)
        XCTAssertNil(appended.0.lines[0].sweptOrder)
        XCTAssertEqual(appended.0.lines[0].order, .extraction,
                       "重排顺序没有东西可显示时不能继续挂着")

        var erased = swept()
        XCTAssertEqual(erased.0.removePoints(of: erased.1) { $0.x == 1 }, 1)
        XCTAssertNil(erased.0.lines[0].sweptOrder)
        XCTAssertEqual(erased.0.lines[0].order, .extraction)

        var replaced = swept()
        replaced.0.replacePoints(of: replaced.1, with: [PixelPoint(x: 0, y: 0)])
        XCTAssertNil(replaced.0.lines[0].sweptOrder)

        var single = swept()
        XCTAssertNotNil(single.0.removePoint(of: single.1, at: 0))
        XCTAssertNil(single.0.lines[0].sweptOrder)
    }

    /// A removal that removes nothing changed nothing, so the sweep stays.
    func testARemovalThatMissesLeavesTheSweepAlone() {
        var (state, id) = stateWithCurve()
        state.recordSweep([2, 0, 1], for: id)
        XCTAssertEqual(state.removePoints(of: id) { $0.x == 99 }, 0)
        XCTAssertEqual(state.lines[0].sweptOrder, [2, 0, 1])
        XCTAssertEqual(state.lines[0].order, .swept)
    }

    func testClearingASweepReturnsTheCurveToItsExtractionOrder() {
        var (state, id) = stateWithCurve()
        state.recordSweep([2, 0, 1], for: id)
        state.clearSweep(for: id)
        XCTAssertNil(state.lines[0].sweptOrder)
        XCTAssertEqual(state.lines[0].order, .extraction)
        XCTAssertEqual(state.lines[0].orderedPoints.map(\.x), [0, 1, 2, 3])
    }

    // MARK: - Persistence

    /// A project file written before this feature existed has no `sweptOrder`
    /// key, and must still open.
    func testAnOlderProjectFileWithoutASweepStillDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "曲线 1",
          "color": { "r": 1, "g": 2, "b": 3 },
          "points": [ { "x": 1, "y": 2 }, { "x": 3, "y": 4 } ],
          "isVisible": true,
          "colorTolerance": 60,
          "order": "extraction"
        }
        """
        let line = try JSONDecoder().decode(CurveLine.self, from: Data(json.utf8))
        XCTAssertNil(line.sweptOrder)
        XCTAssertEqual(line.orderedPoints.count, 2)
    }

    func testASweepSurvivesARoundTrip() throws {
        var (state, id) = stateWithCurve()
        state.recordSweep([3, 1, 0], for: id)

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ProjectState.self, from: data)

        XCTAssertEqual(restored.lines[0].sweptOrder, [3, 1, 0])
        XCTAssertEqual(restored.lines[0].order, .swept)
        XCTAssertEqual(restored.lines[0].orderedPoints.map(\.x), [3, 1, 0, 2])
    }
}
