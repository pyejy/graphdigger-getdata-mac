import Foundation

/// 误差棒的两端偏移,单位是**像素**(与 `PixelPoint` 同一坐标系)。
///
/// 存像素而不是数值:与点本身一致 —— 点也是按像素存、导出时再按曲线所属的
/// 坐标系换算。这样同一批点换一套标定(FR-13 的一图多套坐标系)时,误差跟着
/// 一起换算,不会留下一组按旧标定写死的数。
public struct ErrorBarOffset: Equatable, Codable, Sendable {
    /// 从点向上到上横杠的距离,像素。
    public var up: Double
    /// 从点向下到下横杠的距离,像素。
    public var down: Double

    public init(up: Double, down: Double) {
        self.up = up
        self.down = down
    }
}

/// 误差棒提取 —— B-2,`功能扩展提案.md`。
///
/// 实验图上的数据点常带一根竖线、上下两端各一根小横杠,长度即不确定度。**所有
/// 同类软件都只取点的位置,误差棒要人拿尺子量**(WebPlotDigitizer 的 issue 里
/// 八条评论都在要它,Engauge 与 GetData 都没有)—— 而"连误差一起取出来"正是
/// 加权拟合、误差传递、meta 分析这些二次分析的前提。
///
/// **认的不是"有一条竖线",是"竖线末端的那根横杠"**。这一点是整个算法成立的关键:
/// 竖线本身毫无特征 —— 曲线的一段陡坡、坐标轴的刻度线、网格线都是竖线。而
/// "一条细笔画走到头,末端横向铺开一段稍宽的笔画"是误差棒独有的收尾形状。
/// 只按"竖着走一段"去找,曲线上每一个陡坡都会报出一个误差棒。
///
/// 上下分开量,所以不对称误差(如 +σ/−2σ)原样保留 —— 合成一个 ±值就把信息丢了,
/// 而对称只是常见情形,不是定义。
public enum ErrorBarScanner {

    /// 一次提取的结果,按传入点的顺序一一对应。
    ///
    /// `nil` 表示这个点没有找到误差棒 —— 与"找到了但长度是 0"是两回事,前者是
    /// 没有,后者是量出来为零。界面上不画、导出时留空。
    public struct Result: Equatable, Sendable {
        public var offsets: [ErrorBarOffset?]
        /// 找到的数量,给状态行报数用。
        public var found: Int { offsets.lazy.filter { $0 != nil }.count }
        /// 向上找到了而向下没找到(或反过来)的点的个数 —— 半截的棒,
        /// 值得在状态行里说一声,因为那常常是横杠压着曲线的位置。
        public var halfBars: Int {
            offsets.lazy.filter { offset in
                guard let offset else { return false }
                return (offset.up > 0) != (offset.down > 0)
            }.count
        }
    }

    public struct Parameters: Sendable {
        /// 沿着棒走多远还没遇到横杠就放弃,像素。
        ///
        /// 这个上限是**防"顺着曲线走"**用的,所以它不能是个固定的像素数:合成夹具
        /// 是 640 高的,而真实扫描件常是 3000 高 —— 那里的误差棒 200–300px 很常见,
        /// 写死 90 会把它们全部判成"没有"。实际用的是它和 `maxStemFraction × 图高`
        /// 里**较大**的那个(见 `stemLimit(for:)`)。
        public var maxStemLength: Double = 90
        /// 误差棒长度的上限,按图高的比例 —— 真实图里棒不会长过这个数。
        /// 0.15 是保守的:同一条曲线要走到这么远还遇不到横杠,那多半不是一根棒。
        public var maxStemFraction: Double = 0.15
        /// 走棒时横向允许的晃动:笔画不是完美竖直的,中心每行会漂一两像素。
        public var stemWander: Int = 2
        /// 末端横杠至少要比棒身宽多少像素才算"横杠"。太小的阈值会把笔画
        /// 加粗处当成横杠。
        public var minCapOverhang: Int = 3
        /// 横杠自身的最大宽度(半宽),超出就不像误差棒的帽子,更像曲线拐弯。
        public var maxCapHalfWidth: Int = 12
        /// 末端这几行里出现横杠就算数 —— 抗锯齿会让最后一两行淡掉。
        public var capSearchDepth: Int = 3
        /// 整段行走允许的**累计**横向漂移,像素。
        ///
        /// 这是"顺着曲线走"的终止条件,也是最要紧的一条:误差棒是竖直的,棒身
        /// 走几十行横坐标也只动一两像素;而曲线只要不是完全竖直,走几十行就偏出
        /// 一大截。实测在一条普通曲线上(线宽 3),没有这一条时 40 个探测点里
        /// 会误报 2 个 —— 它们都是"沿曲线走了 60 多行,末端宽度爬升到够宽"。
        /// 逐行的 `stemWander` 拦不住它(每行只漂 1px 也是合法的棒),累计量才拦得住。
        public var maxDrift: Int = 4

        public init() {}
    }

    /// 颜色无关的"有墨"遮膜:凡是明显不同于背景的像素。
    ///
    /// 它的用处只有一个,但很要紧 —— 回答「为什么一个都没找到」:是这张图本来
    /// 没画误差棒,还是**棒有、只是不是曲线的颜色**(彩色曲线配黑色误差棒极常见,
    /// 而取点用的遮膜只认曲线那一种颜色)。没有这一层,两种完全不同的原因会共用
    /// 同一句"没找到",用户只能猜。
    public static func inkMask(from buffer: BitmapBuffer, background: RGB8,
                               threshold: Double = 60) -> ForegroundMask {
        let n = buffer.width * buffer.height
        var bits = [Bool](repeating: false, count: n)
        let br = Double(background.r), bg = Double(background.g), bb = Double(background.b)
        let limit = threshold * threshold
        buffer.pixels.withUnsafeBufferPointer { px in
            bits.withUnsafeMutableBufferPointer { out in
                for i in 0..<n {
                    let base = i * 3
                    let dr = Double(px[base]) - br
                    let dg = Double(px[base + 1]) - bg
                    let db = Double(px[base + 2]) - bb
                    // 与曲线无关的加权距离:任何"够暗/够有色"的东西都算墨。
                    out[i] = (2 * dr * dr + 4 * dg * dg + 3 * db * db) > limit
                }
            }
        }
        return ForegroundMask(width: buffer.width, height: buffer.height, bits: bits)
    }

    /// 对给定的点逐个找误差棒。
    ///
    /// `points` 是要量的位置(像素),`mask` 是曲线颜色的遮膜 —— 用遮膜而不是
    /// 原图,是因为误差棒与曲线通常同色,而遮膜已经把"不是这个颜色的东西"
    /// 挡在外面了(顺带还有第四道闸门:去网格线,B-1)。
    public static func scan(points: [PixelPoint],
                            mask: ForegroundMask,
                            parameters: Parameters = Parameters()) -> Result {
        var offsets: [ErrorBarOffset?] = []
        offsets.reserveCapacity(points.count)
        for point in points {
            let x = Int(point.x.rounded())
            let y = Int(point.y.rounded())
            guard x >= 0, x < mask.width, y >= 0, y < mask.height else {
                offsets.append(nil)
                continue
            }
            let limit = stemLimit(for: mask, parameters: parameters)
            let up = distance(toCapFrom: (x, y), direction: -1, mask: mask,
                              parameters: parameters, limit: limit)
            let down = distance(toCapFrom: (x, y), direction: +1, mask: mask,
                                parameters: parameters, limit: limit)
            if up == nil && down == nil {
                offsets.append(nil)
            } else {
                offsets.append(ErrorBarOffset(up: up ?? 0, down: down ?? 0))
            }
        }
        return Result(offsets: offsets)
    }

    // MARK: - 沿一根棒走到底

    /// 从 (x, y) 沿 `direction` 方向走,返回"到横杠的距离";没找到横杠返回 nil。
    ///
    /// 走的时候把每一行的墨宽记下来,三条规则定案:
    ///
    /// 1. **棒身宽度取中位数** —— 不能取最大值。从点出发的头几行落在**标记本身**
    ///    里(圆点比棒身宽得多),取最大值会把棒身当成 9px 宽,于是真正的横杠
    ///    (11px)不再"更宽",认不出来。而中位数稳得多:棒身占绝大多数行。
    /// 2. **横杠 = 末端几行里突然变宽的那一行**,不是"末端之外"的行 —— 横杠本身
    ///    就是笔画的中点,它能被窗口看到,行走会穿过它停在它外面。
    /// 3. 从末端往里找,超过 `capSearchDepth` 就不算 —— 半路上的一次加粗
    ///    (曲线拐弯、刻度线)不叫帽子。
    /// 走多远算走远了:固定的像素下限与"图高的一个比例"取较大者。
    private static func stemLimit(for mask: ForegroundMask,
                                  parameters: Parameters) -> Double {
        Swift.max(parameters.maxStemLength,
                  Double(mask.height) * parameters.maxStemFraction)
    }

    private static func distance(toCapFrom origin: (x: Int, y: Int),
                                 direction: Int,
                                 mask: ForegroundMask,
                                 parameters: Parameters,
                                 limit: Double) -> Double? {
        var centre = origin.x
        var walked: [(row: Int, width: Int)] = []
        var step = 0

        while Double(step) < limit {
            step += 1
            let row = origin.y + direction * step
            guard row >= 0, row < mask.height else { break }
            guard let inkCentre = inkCentre(inRow: row, around: centre,
                                            mask: mask,
                                            window: parameters.stemWander) else { break }
            centre = inkCentre
            guard abs(centre - origin.x) <= parameters.maxDrift else { break }
            walked.append((row, inkRun(inRow: row, around: centre, mask: mask).count))
        }

        // 至少要走出一小段才算一根棒:只走一两行的话那是标记自己的边。
        guard walked.count >= 4 else { return nil }

        var widths = walked.map(\.width).sorted()
        let stemWidth = widths[widths.count / 2]
        widths.removeAll()

        let stemLimit = stemWidth + parameters.minCapOverhang
        let capWidthLimit = parameters.maxCapHalfWidth * 2
        for depth in 0...parameters.capSearchDepth {
            let index = walked.count - 1 - depth
            guard index >= 0 else { break }
            let entry = walked[index]
            guard entry.width >= stemLimit, entry.width <= capWidthLimit else { continue }
            // **横杠是台阶,不是渐变。** 曲线走到末端也会变宽(笔画在拐弯处横向
            // 铺开、两条近乎平行的边并到一起),只看"末端有一行更宽"会把它当成
            // 误差棒 —— 实测在一条普通曲线上 40 个探测点里就会误报 2 个。
            // 真正的横杠:紧挨着它的那一行仍然是窄的棒身。渐变则会一行比一行宽。
            let inside = walked[Swift.max(0, index - 1)].width
            guard inside <= stemWidth + 2 else { continue }
            return Double(abs(entry.row - origin.y))
        }
        return nil
    }

    /// 某一行里、以 `centre` 为中心的一段连续墨迹。返回它的起止列。
    ///
    /// 从中心向两侧各走一步,发现没墨就停 —— 不设固定宽度,因为误差棒的帽子
    /// 有长有短,而"连续"这个性质是它和旁边的曲线区分开的依据。
    private static func inkRun(inRow row: Int, around centre: Int,
                               mask: ForegroundMask) -> (start: Int, end: Int, count: Int) {
        guard centre >= 0, centre < mask.width, mask.isForeground(x: centre, y: row) else {
            return (0, -1, 0)
        }
        var left = centre
        while left - 1 >= 0, mask.isForeground(x: left - 1, y: row) { left -= 1 }
        var right = centre
        while right + 1 < mask.width, mask.isForeground(x: right + 1, y: row) { right += 1 }
        return (left, right, right - left + 1)
    }

    /// 一行里窗口内墨迹的中心列,没有墨返回 nil。
    private static func inkCentre(inRow row: Int, around centre: Int,
                                  mask: ForegroundMask, window: Int) -> Int? {
        var sum = 0
        var count = 0
        for x in (centre - window)...(centre + window) {
            guard x >= 0, x < mask.width else { continue }
            if mask.isForeground(x: x, y: row) {
                sum += x
                count += 1
            }
        }
        return count == 0 ? nil : Int((Double(sum) / Double(count)).rounded())
    }
}
