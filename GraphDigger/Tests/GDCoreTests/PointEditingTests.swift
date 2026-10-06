import XCTest
@testable import GDCore

/// Editing individual points: the order arithmetic underneath FR-6.4 and FR-7.2.
///
/// The whole difficulty is that a curve is stored in extraction order and
/// *displayed* in some other order, and the two are different permutations the
/// moment the user picks X 升序 or sweeps the ring brush. Everything here is
/// about that gap: which stored point a displayed marker is, and where a new
/// point goes so that it comes out between the two markers it was dropped
/// between.
final class PointEditingTests: XCTestCase {

    private func state(_ coordinates: [(Double, Double)],
                       order: PointOrder = .extraction,
                       sweptOrder: [Int]? = nil) -> (state: ProjectState, id: UUID) {
        var project = ProjectState()
        let id = project.addLine(name: "测试曲线", color: RGB8(r: 200, g: 0, b: 0))
        project.replacePoints(of: id,
                              with: coordinates.map { PixelPoint(x: $0.0, y: $0.1) })
        project.setOrder(order, for: id)
        if let sweptOrder { project.recordSweep(sweptOrder, for: id) }
        return (project, id)
    }

    // MARK: - One order, two expressions

    /// The displayed points must be exactly the stored ones looked up through
    /// the index list. If the two ever disagree, every editor that trusts the
    /// indices is writing to points the user cannot see.
    func testTheIndexedOrderAndThePointwiseOrderAgree() {
        // Duplicate x on purpose. Ties are the part a re-derived sort gets wrong,
        // and the two expressions agreeing about *which* of two points with the
        // same x comes first is the property that matters.
        let coordinates = [(3.0, 1.0), (1.0, 5.0), (2.0, 9.0), (1.0, 2.0), (3.0, 7.0)]
        let points = coordinates.map { PixelPoint(x: $0.0, y: $0.1) }

        for order in PointOrder.allCases {
            let indices = order.applyIndices(to: points)
            XCTAssertEqual(indices.sorted(), Array(points.indices),
                           "\(order.displayName):索引不是 0..<n 的一个排列")
            XCTAssertEqual(indices.map { points[$0] }, order.apply(to: points),
                           "\(order.displayName):两种写法给出的顺序不一致")
        }
    }

    /// Same property for the sweep, which resolves through a different path.
    func testTheSweepHasOneOrderExpressedTwoWays() {
        let points = (0..<6).map { PixelPoint(x: Double($0), y: Double($0) * 2) }
        let sequence = [3, 1, 4]                    // 0、2、5 没有被扫到

        let byPoints = SweepReorder.resolve(points, sequence: sequence)
        let byIndices = SweepReorder.resolveIndices(pointCount: points.count, sequence: sequence)

        XCTAssertEqual(byIndices.sweptCount, byPoints.sweptCount)
        XCTAssertEqual(byIndices.indices.map { points[$0] }, byPoints.points)
        XCTAssertEqual(byIndices.indices.count, points.count, "不能丢点也不能重复")
        XCTAssertEqual(Array(byIndices.indices[byIndices.sweptCount...]), [0, 2, 5],
                       "没扫到的要排在末尾,且保持原来的先后")
    }

    func testACurveOrdersItsPointsTheSameWayItsIndicesSay() {
        for order in PointOrder.allCases {
            let (project, id) = state([(10, 0), (50, 0), (30, 0), (70, 0)],
                                      order: order,
                                      sweptOrder: order == .swept ? [2, 0, 3, 1] : nil)
            guard let line = project.lines.first(where: { $0.id == id }) else {
                return XCTFail("曲线没建出来")
            }
            XCTAssertEqual(line.orderedPointIndices.map { line.points[$0] },
                           line.orderedPoints,
                           "\(order.displayName):显示序与索引表不一致")
        }
    }

    // MARK: - Insertion position

    /// Orders that present the stored sequence as it is, front-to-back or
    /// back-to-front. On these a displayed position is a fixed permutation of a
    /// stored one, so "between these two markers" is a question the insertion can
    /// actually answer.
    func testInsertingIntoASegmentLandsBetweenItsTwoEnds() {
        let coordinates = [(10.0, 0.0), (50.0, 0.0), (30.0, 0.0), (70.0, 0.0), (20.0, 0.0)]

        for order in [PointOrder.extraction, .reversed] {
            let (initial, id) = state(coordinates, order: order)
            guard let line = initial.lines.first(where: { $0.id == id }) else {
                return XCTFail("曲线没建出来")
            }
            // The **displayed** order, not the stored one. On a reversed curve
            // the two are mirror images, and comparing against the stored array
            // is how a test ends up asserting the bug it was written to catch.
            let before = line.orderedPoints
            for segment in 0..<(before.count - 1) {
                guard let at = line.storedInsertionIndex(betweenDisplayIndex: segment) else {
                    return XCTFail("\(order.displayName):段 \(segment) 没有插入位置")
                }
                let marker = PixelPoint(x: -999, y: -999)
                var edited = initial
                XCTAssertTrue(edited.insertPoint(of: id, at: at, point: marker))
                guard let editedLine = edited.lines.first(where: { $0.id == id }),
                      let position = editedLine.orderedPoints.firstIndex(of: marker) else {
                    return XCTFail("\(order.displayName):插入的点没出现在显示序里")
                }
                let displayed = editedLine.orderedPoints
                if position > 0 {
                    XCTAssertEqual(displayed[position - 1], before[segment],
                                   "\(order.displayName) 段 \(segment):前一个邻居不是线段起点")
                }
                if position + 1 < displayed.count {
                    XCTAssertEqual(displayed[position + 1], before[segment + 1],
                                   "\(order.displayName) 段 \(segment):后一个邻居不是线段终点")
                }
            }
        }
    }

    /// The orders that re-sort. There is no "between" to honour — the new point
    /// goes wherever its own x says — so the property that has to survive an
    /// insert is that the curve is still in the order the setting promises.
    func testInsertingIntoASortedCurveLeavesItSorted() {
        let coordinates = [(10.0, 0.0), (50.0, 0.0), (30.0, 0.0), (70.0, 0.0)]
        for order in [PointOrder.ascendingX, .descendingX] {
            let (project, id) = state(coordinates, order: order)
            guard let line = project.lines.first(where: { $0.id == id }),
                  let at = line.storedInsertionIndex(betweenDisplayIndex: 1) else {
                return XCTFail("\(order.displayName):没有插入位置")
            }
            var edited = project
            // Deliberately a value that belongs in the middle of the range, not
            // at either end: an implementation that appended would still pass a
            // check made with the largest x, and this is the case that matters.
            XCTAssertTrue(edited.insertPoint(of: id, at: at,
                                             point: PixelPoint(x: 40, y: 0)))
            guard let xs = edited.lines.first(where: { $0.id == id })?.orderedPoints.map(\.x) else {
                return XCTFail("曲线没找到")
            }
            XCTAssertEqual(xs.count, coordinates.count + 1, "点没插进去")
            let expected: [Double] = order == .ascendingX ? xs.sorted() : xs.sorted().reversed()
            XCTAssertEqual(xs, expected, "\(order.displayName):插入后顺序不再是它承诺的那样")
        }
    }

    func testThereIsNoInsertionPositionAtTheLastMarkerOrOutsideTheRange() {
        let (project, id) = state([(0, 0), (10, 0), (20, 0)])
        guard let line = project.lines.first(where: { $0.id == id }) else {
            return XCTFail("曲线没建出来")
        }
        XCTAssertNil(line.storedInsertionIndex(betweenDisplayIndex: 2),
                     "最后一个标记之后没有线段")
        XCTAssertNil(line.storedInsertionIndex(betweenDisplayIndex: 7), "越界要拒绝")
        XCTAssertNotNil(line.storedInsertionIndex(betweenDisplayIndex: 1))
    }

    // MARK: - What each edit does to the sweep

    /// A move keeps the sweep; an insert or a delete drops it.
    ///
    /// Not a detail. The sweep is a list of **indices**, so moving a point leaves
    /// every one of them naming the same point, while inserting renumbers the
    /// tail. Dropping the record on a move would cost the user an ordering that
    /// took a minute of sweeping to get right, over a nudge of three pixels —
    /// and they would only find out when the polyline rearranged itself.
    func testMovingKeepsTheSweepAndInsertingOrDeletingDropsIt() {
        let coordinates = [(0.0, 0.0), (10.0, 0.0), (20.0, 0.0), (30.0, 0.0)]
        let swept = [2, 0, 1, 3]

        var (moved, movedID) = state(coordinates, order: .swept, sweptOrder: swept)
        XCTAssertTrue(moved.movePoint(of: movedID, at: 1, to: PixelPoint(x: 10, y: 4)))
        XCTAssertEqual(moved.lines.first(where: { $0.id == movedID })?.sweptOrder, swept,
                       "移动不该作废扫掠记录")
        XCTAssertEqual(moved.lines.first(where: { $0.id == movedID })?.order, .swept)

        var (inserted, insertedID) = state(coordinates, order: .swept, sweptOrder: swept)
        XCTAssertTrue(inserted.insertPoint(of: insertedID, at: 2, point: PixelPoint(x: 15, y: 0)))
        XCTAssertNil(inserted.lines.first(where: { $0.id == insertedID })?.sweptOrder,
                     "插入之后旧的下标全体错位,记录必须作废")
        XCTAssertEqual(inserted.lines.first(where: { $0.id == insertedID })?.order, .extraction,
                       "把记录作废却留着「重排顺序」,菜单就在撒谎")

        var (removed, removedID) = state(coordinates, order: .swept, sweptOrder: swept)
        XCTAssertNotNil(removed.removePoint(of: removedID, at: 1))
        XCTAssertNil(removed.lines.first(where: { $0.id == removedID })?.sweptOrder)
    }

    /// Moving writes the **stored** point the displayed marker stands for.
    ///
    /// Set up so the two numbers differ as much as possible: on a reversed curve
    /// the first marker on screen is the last point in storage. An editor that
    /// used the displayed position as an index would move the point at the other
    /// end and leave the grabbed one untouched — which looks like the drag
    /// working, until you notice which end of the curve moved.
    func testMovingWritesTheStoredPointNotTheDisplayedPosition() {
        let coordinates = [(0.0, 0.0), (10.0, 0.0), (20.0, 0.0), (30.0, 0.0)]
        var (project, id) = state(coordinates, order: .reversed)
        guard let line = project.lines.first(where: { $0.id == id }) else {
            return XCTFail("曲线没建出来")
        }
        let storedIndex = line.orderedPointIndices[0]
        XCTAssertEqual(storedIndex, 3, "反转序的第一个标记应当是存储里的最后一个点")

        let moved = PixelPoint(x: 30, y: 99)
        XCTAssertTrue(project.movePoint(of: id, at: storedIndex, to: moved))
        guard let after = project.lines.first(where: { $0.id == id }) else {
            return XCTFail("曲线不见了")
        }
        XCTAssertEqual(after.points[3], moved, "该动的那个点没动")
        XCTAssertEqual(after.points[0], PixelPoint(x: 0, y: 0), "不该动的点被动了")
        XCTAssertEqual(after.orderedPoints.first, moved, "显示序开头应当还是它")
    }

    func testMovingNowhereReportsNothingChanged() {
        var (project, id) = state([(0.0, 0.0), (10.0, 0.0)])
        let same = PixelPoint(x: 0, y: 0)
        XCTAssertFalse(project.movePoint(of: id, at: 0, to: same),
                       "没有位移就要报 false,否则一次点空也会进撤销栈")
        XCTAssertFalse(project.movePoint(of: id, at: 9, to: same), "越界要拒绝")
        XCTAssertFalse(project.movePoint(of: UUID(), at: 0, to: same), "不存在的曲线要拒绝")
    }
}
