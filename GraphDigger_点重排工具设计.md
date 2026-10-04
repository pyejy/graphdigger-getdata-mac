# GraphDigger · 点重排工具设计（Sweep Reorder）

| 项目 | 内容 |
|---|---|
| 文档版本 | v0.2（P1–P3 已落地，见 §11） |
| 日期 | 2026-10-01 |
| 关联文档 | 《GetData复刻_功能需求文档.md》(FRD)、《GetData复刻_开发环境与架构设计.md》 |
| 目标工具 | 用「圈刷」扫过已提取的点，按扫过的先后给点重新编号，从而重建曲线 |
| 影响范围 | `GDCore`（模型）＋ `GraphDiggerApp`（交互），不改算法层 |

---

## 1. 要解决的问题

### 1.1 现象

区域取点（FR-5.2）在**非单值曲线**上取出的点，顺序天然是错的：

- 网格取点按列扫描，产出的是「列优先」的点集；
- 现有 `PointOrder` 能把它们排成 `X 升序 / X 降序 / 反转`；
- 但**圆、椭圆、闭合回路、回折曲线、垂直段**这类曲线，任何一个全局排序规则都排不对——
  同一个 x 对应多个 y，按 x 排出来的折线会在图上横跳。

用户现在的补救手段是「橡皮擦删掉重来」或「重新选点」，
但这两种都是**破坏性的**，删掉就没了。

### 1.2 为什么现有机制不够

`PointOrder` 的四种模式（`extraction / ascendingX / descendingX / reversed`）
都是**点集位置的纯函数**——同一堆点，谁调用都得到同一个结果。

而「正确的顺序」在非单值曲线上**取决于用户脑子里的那条曲线**，
不是点集自身的性质。所以它**不可能**被表达成 `PointOrder` 里的一个纯函数。
必须有人的手势参与 → 必须是一个**交互工具**，不是一个排序选项。

这正是本设计的立足点。

### 1.3 目标

| # | 目标 | 判据 |
|---|---|---|
| G1 | 用一圈刷扫过曲线，点被按扫过顺序重编号 | 扫完全部点后，折线与真实曲线重合 |
| G2 | 非破坏性 | 扫坏了能重来；原始取点顺序随时可恢复 |
| G3 | 快速扫不出错 | 手速再快也不能漏点、不能编号跳错 |
| G4 | 进度可见 | 随时知道「还剩多少点没扫到」 |
| G5 | 复用既有交互习惯 | 圈的大小、调整方式与橡皮擦一致 |

---

## 2. 交互设计

### 2.1 工具形态：一个圈刷

与橡皮擦 (FR-6.x) 完全同构，用户不需要学第二套手势：

| 维度 | 橡皮擦 | 点重排（本工具） |
|---|---|---|
| 形状 | 圆环，跟随指针 | 圆环，**同样跟随指针** |
| 半径 | `eraserRadius`（视点，`[` `]` 与信息栏滑槽调整） | **共用同一个半径值** |
| 触发 | 按下即生效，拖拽连续作用 | 按下开始一笔，拖拽连续作用 |
| 视觉 | 白色光晕 + 红环 + 圆心点 | 同结构，**换配色**（见 §2.4） |

> **共用半径的理由**：两个工具都是「一个圈」，让用户记住两个口径是没必要的负担；
> 信息栏那个读数同时是两者的口径，含义不变。
>
> 该控件已按用户反馈改过（2026-10-01 落地）：一是**只在两个圈工具被选中时出现**
> ——常驻时它在「手工取点」下也亮着，读起来像是橡皮擦还暗中armed；二是 `− ⌀NN +`
> 步进按钮换成**滑槽**，6–120pt 的行程一次拖到位，尺寸边拖边在画布上可见。
> 读数同时从 `⌀` 改成 `半径`——原标注按直径写，实际是半径，差了一倍。

### 2.2 核心手势语义

```
按下            → 开始一笔（stroke），笔的顺序计数器归零
拖动            → 圈扫到的新点，按“扫过的先后”依次取得 1、2、3…
松开            → 这一笔结束
```

**三条关键规则：**

1. **已扫过的点不会重复计号。** 圈再扫回去，那个点保持它原有的序号。
   → 可以分多笔慢慢扫，不必一笔画完。
2. **一笔内的顺序 = 圈心沿指针轨迹前进的先后。** 不是「离圆心远近」，见 §3。
3. **没扫到的点排在最后**，并保持它们原有的相对次序。
   → 它们会在图上以「一串乱跳的折线」显形，正好提示用户还没扫完。

### 2.3 进度反馈

信息栏状态行实时显示：

```
重排 37/120 点 —— 继续用圈扫过剩下的点
```

- 全部扫完 → `重排完成 120/120 点 —— 折线已按扫过顺序重建`
- 这是 G4 的落点，也是用户判断「可以松手了」的唯一依据。

### 2.4 视觉反馈（三处，都不需要新写渲染器）

| 元素 | 做法 | 复用的现成设施 |
|---|---|---|
| 圈刷本体 | 白晕 + **橙色**环（橡皮擦是红环，两者不能混淆） | `drawToolRing()` 换配色 |
| 已扫点的序号 | 圈扫过的点立刻显示 `1 2 3 …` | **`drawSequenceNumbers()` 现成** |
| 未扫点 | 降低不透明度，与已扫点拉开对比 | `drawCurve()` 内按是否已扫分两组画 |

> 第三项是本工具最重要的可读性来源：用户扫到一半时，
> 图上应该一眼能分出「已经排好的」和「还没排的」。

### 2.5 入口与重置

**入口（受 §6 宽度硬约束限制，见下）**：菜单 `Operations ▸ Reorder Points (点重排)`，快捷键 **⌘B**。

**重置**：把侧栏「取点顺序」下拉切回 `取点顺序` 即恢复原始顺序（§4.2 保证这一步无损耗）。
另提供菜单项 `Clear Reorder (清除重排)` 直接清空扫过的记录。

---

## 3. 核心算法：为什么不能只看「离圆心远近」

### 3.1 难点

鼠标事件是**离散采样**的。手快的时候，两个相邻事件之间指针已经走出去几十甚至上百像素，
而圈半径可能只有 18pt。直接拿「当前圈内的点」编号，会同时犯两个错：

- **漏点**：两次采样之间的那一段曲线，圈从没停在那里，点被整段跳过；
- **错序**：一次事件圈进一大把点，这些点之间谁先谁后，
  「离圆心近」和「沿轨迹先被扫到」是两回事。

### 3.2 解法：路径重采样 + 沿运动方向投影

两件事同时做：

**(a) 把位移拆成小步，杜绝漏点**

每一段位移（上一个圆心 → 当前圆心）按 `半径 × 0.5` 的步长插值，
在每一个中间圆心处各做一次采集。步长取半径的一半，保证相邻两个采样圈必有大面积重叠，
**曲线不可能从两圈之间漏过去**。

**(b) 同一小步内的点，按在运动方向上的投影排序**

对刚进圈的点 `p`，取它相对圆心的位移 `v = p − center`，
在运动方向 `d` 上的投影 `proj = (v · d) / |d|`，按 `proj` 升序。
投影小的先被扫到，大的后被扫到——这与几何直觉一致，也与用户手的运动一致。

**退化情形**：原地点击（`|d| ≈ 0`）没有方向信息，退化为按 `|v|`（离圆心近的先）。
这是无法避免的信息缺失，如实写进「已知限制」，并建议用户不要用原地点击来排序。

### 3.3 伪代码

```swift
// ── 一笔的生命周期 ──────────────────────────────────────────────
private var strokeLastCenter: PixelPoint?
private var strokeSwept: Set<Int> = []          // 本笔已计号的点下标

func beginReorderStroke(at p: PixelPoint) {
    strokeLastCenter = p
    capture(around: p, direction: nil)           // 原地按下：按距离编号
}

func extendReorderStroke(to p: PixelPoint) {
    guard let last = strokeLastCenter else { return }
    let d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
    let dist = hypot(d.dx, d.dy)
    let r = reorderRadius / viewScale            // 视点 → 图像像素

    // (a) 重采样：步长 = 半径的一半，确保不漏点
    let step = max(r * 0.5, 1.0)
    let n = max(1, Int(ceil(dist / step)))
    for s in 1...n {
        let t = Double(s) / Double(n)
        let c = PixelPoint(x: last.x + d.dx * t, y: last.y + d.dy * t)
        capture(around: c, direction: d)         // (b) 内部按投影排序
    }
    strokeLastCenter = p
}

// ── 单次采集 ────────────────────────────────────────────────────
private func capture(around center: PixelPoint, direction: CGVector?) {
    let r = reorderRadius / viewScale
    var fresh: [(index: Int, key: Double)] = []

    for (i, p) in points.enumerated() where !isSwept(i) {
        let vx = p.x - center.x, vy = p.y - center.y
        guard vx * vx + vy * vy <= r * r else { continue }   // 圈内

        let key: Double
        if let d = direction, d.dx != 0 || d.dy != 0 {       // (b) 投影
            key = (vx * d.dx + vy * d.dy) / hypot(d.dx, d.dy)
        } else {                                             // 退化：距圆心
            key = hypot(vx, vy)
        }
        fresh.append((i, key))
    }

    fresh.sort { $0.key < $1.key }                            // 先后稳定
    for f in fresh {                                          // 依次追加计号
        sweptOrder.append(f.index)
        strokeSwept.insert(f.index)
    }
}
```

### 3.4 性能预算

单次采集是 `O(N)`（N = 该曲线点数）扫描 + 一次小规模排序。
最坏情形：拖 200px、半径 18pt（图像空间约 18px，步长 9）→ 22 次采样子步 × N。

| 点数 N | 每次鼠标事件代价 | 结论 |
|---|---|---|
| ≤ 1 000（区域取点典型量级） | ~2 万次距离比较 | 直接可行，无需优化 |
| ~10 000（极端密网格） | ~22 万次／事件，60Hz 下吃紧 | 建议加**均匀网格索引**：一笔开始时把点装进格子，采集只查邻近格 |

> 网格索引与 `ProjectState.gridSpacing` 是同一个思路，实现成本低；
> 但属于优化项，**第一版不必做**，先用 `O(N)` 跑通，实测卡顿再加。

---

## 4. 数据模型：怎么存「扫过的顺序」

### 4.1 两个方案

**方案 A：直接置换 `CurveLine.points`**

按扫过顺序重排 `points` 数组本身。约 30 行，最简单。

- ❌ 破坏原始取点顺序 → `PointOrder.extraction`（「取点顺序」）从此名不副实
- ❌ 本应用**没有撤销系统**（FR-6.5 未实现），扫坏了无法恢复
- ✅ 好处：不新增字段，不动 `Codable`

**方案 B：另存一份「扫过的下标序列」（推荐）**

`points` 永远是原始记录，扫过的顺序单独存：

```swift
// CurveLine
/// `points` 的下标，按「点重排」圈刷扫过的先后排列。nil / 空 = 从未扫过。
public var sweptOrder: [Int]?
```

排序解析放在 `CurveLine`：

```swift
public var orderedPoints: [PixelPoint] {
    if order == .swept, let seq = sweptOrder, !seq.isEmpty {
        var taken = [Bool](repeating: false, count: points.count)
        var out: [PixelPoint] = []
        out.reserveCapacity(points.count)
        for i in seq where i >= 0 && i < points.count && !taken[i] {
            taken[i] = true
            out.append(points[i])
        }
        // 没扫到的点排在最后，保持原有相对次序
        for (i, p) in points.enumerated() where !taken[i] { out.append(p) }
        return out
    }
    return order.apply(to: points)
}
```

- ✅ 原始顺序完好 → 「取点顺序」随时可以把曲线还原成没扫过的样子
- ✅ 切换顺序模式**零损耗**，`sweptOrder` 不会被清掉，切回来还在
- ✅ 越界/重复下标被 `taken` 数组兜住，脏数据不会崩
- ⚠️ 成本：多两个改动点（枚举加一例、`orderedPoints` 加分支）

**推荐 B**，理由是它和本项目既有的两条设计原则一致：

> 「点存像素坐标而非数值，所以重新标定会自动更新所有曲线」——**不锁死中间结果**
> 「每个模式都是原始取点顺序的纯函数，所以没有任何模式会破坏信息」——**不破坏信息**

A 方案恰恰违反后者。

### 4.2 与 `PointOrder` 的关系

在 `PointOrder` 增加一例：

```swift
/// 按「点重排」圈刷扫过的先后。**具体次序存在 CurveLine.sweptOrder 上**，
/// 本枚举只负责标记「当前使用扫过顺序」。单独调用 apply(to:) 时等价于原序。
case swept
```

`displayName` → `"重排顺序"`。

这一例会**自动**出现在两个已有的 UI 里，因为它们都在遍历 `allCases`：
- 侧栏「取点顺序」下拉（`SidebarView` 第 148 行）
- 菜单 `Operations ▸ Point Order`（`AppDelegate` 第 181 行）

**入口基本白送**，这也是选 B 的一个附带收益。

### 4.3 失效规则（必须做，否则会错位）

`sweptOrder` 存的是**下标**，一旦 `points` 增删，下标就全部错位。规则：

> **任何增删点的路径，都必须同时清空 `sweptOrder`。**

需要覆盖的调用点：

| 位置 | 操作 |
|---|---|
| `ProjectState.append(points:)` | 追加点（手工取点 / 区域取点 / 自动跟踪） |
| `ProjectState.replacePoints(of:with:)` | 整体替换 |
| `CanvasView.erase(at:)` | 橡皮擦 —— **当前是直接 `points.removeAll`，要改成走 `ProjectState`** |
| `CanvasView.redigitize(...)` | 重新选点（内部同样是直接 `removeAll` + `append`） |

建议：把这三处直接改数组的写法统一收进 `ProjectState` 的方法里，
让「改点」和「失效重排」成为一个不可分割的动作，而不是靠调用方记得。

读取侧再加一道保险：`seq` 中越界下标直接丢弃（§4.1 的 `taken` 已经处理）。

---

## 5. 接线点清单（改动落点）

### 5.1 GDCore

| 文件 | 改动 |
|---|---|
| `PointOrder.swift` | 加 `case swept` + `displayName`；`apply(to:)` 对 `.swept` 返回原序并注明 |
| `CurveLine.swift` | 加 `sweptOrder: [Int]?` 字段、`orderedPoints` 分支；`CurveLine.init` 加默认参数 `sweptOrder: nil` |
| `CurveLine.swift` | `ProjectState` 的增删点方法中清空 `sweptOrder` |

> `sweptOrder` 是 `Optional`，Swift 合成的 `Codable` 对可选属性用 `decodeIfPresent`，
> **旧工程文件缺这个键会解码为 `nil`**，向后兼容不需要额外处理。

### 5.2 GraphDiggerApp

| 文件 | 改动 |
|---|---|
| `CanvasView.swift` | `ToolMode` 加 `case reorder`；`hint` / `tracksPointer` / `resetCursorRects` 各加一例 |
| `CanvasView.swift` | 三个鼠标方法加 `.reorder` 分支（`mouseDown` / `mouseDragged` / `mouseUp`） |
| `CanvasView.swift` | 新增 `beginReorderStroke` / `extendReorderStroke` / `capture`（§3.3） |
| `CanvasView.swift` | `drawToolRing()` 支持 `.reorder`（橙色环）；`drawCurve()` 分组画已扫/未扫 |
| `CanvasView.swift` | `keyDown` 里 `[` `]` 已经改的是共用半径，**无需改动** |
| `AppDelegate.swift` | 菜单 `Operations` 加 `Reorder Points (点重排)` ⌘B、`Clear Reorder (清除重排)` |
| `AppDelegate.swift` | `refreshUI()` 增加重排进度文案（§2.3）；`isLoadingEnabled` 门控 |
| `AppDelegate.swift` | `applyTool` 加 `"reorder"` 分支 |

### 5.3 光标

`resetCursorRects` 里给 `.reorder` 一个**与现有工具都不同**的光标。
现有：`openHand`(浏览) / `disappearingItem`(橡皮) / `crosshair`(标定等一大批)。
建议 `.reorder` 用 `.openHand` 之外的独立项——实际区分主要靠**圈刷的橙色环**，
光标只要不误导即可（推荐 `.crosshair` 之外的 `NSCursor.operationNotAllowed` 不适用，
建议直接用 `.crosshair` 并接受它与取点类工具共享，靠环色区分）。

---

## 6. 硬约束：工具栏已经放不下第 9 个按钮

这是**实测数据**，不是估算。当前自检输出：

```
[ ok ] 工具栏按钮数量  — 11 个按钮
[ ok ] 工具栏宽度自洽  — 窗口 1430 pt / 屏幕 1440 pt
[ ok ] 最小窗口宽度下工具栏按钮仍然完整  — 窗口 1430 pt = 工具栏 1158 + 面板 272
```

`MainLayout.windowMinimumWidth(toolbarWidth:) = max(toolbarWidth, 900) + 272`，
且自检断言 `窗口 ≤ narrowestScreenWidth = 1440 pt`。

| 项 | 值 |
|---|---|
| 当前工具栏宽 | **1158 pt** |
| 加上面板后的窗口 | **1430 pt** |
| 最窄屏幕 | 1440 pt |
| **剩余余量** | **10 pt** |

**结论：任何新按钮（约 110–130 pt）都会让窗口涨到 1540 pt 以上，直接越过小屏上限，自检当场变红。**

### 三个可选出路

**① 不做工具栏按钮，只走菜单（推荐先这样）**
`Operations ▸ Reorder Points` ⌘B。零宽度成本，先验证功能本身是否好用。

**② 精简已有按钮文案，腾出空间**
把偏长的按钮改成短标签（当前都是「图标 + 中文」，每字约 12pt）：

| 现文案 | 建议 | 省 |
|---|---|---|
| 区域取点 | 区域 | ~24 pt |
| 自动跟踪 | 跟踪 | ~24 pt |
| 手工取点 | 取点 | ~24 pt |
| 复制数据 | 复制 | ~24 pt |
| 适配窗口 | 适配 | ~24 pt |
| 重新选点 | 重取 | ~24 pt |

全改掉约省 **144 pt**，`1158 − 144 + 125 ≈ 1139` → 窗口 `1411 pt`，**能装下**。
代价是牺牲文案自明性（这几个词对新手来说是主要指引），需要权衡。

**③ 加第二排工具栏 / 溢出菜单**
结构改动大，不是这一版该做的事。

> 建议：**先按 ① 落地**，用起来觉得顺手再按 ② 换一个工具栏位。

---

## 7. 边界情况与已知限制

| 情形 | 行为 | 说明 |
|---|---|---|
| 原地点击（无位移） | 按「离圆心近的在前」编号 | 缺方向信息，无法还原真实先后。**不建议用它排序**，只适合补漏 |
| 快速甩动 | 由 §3.2(a) 的重采样兜住，不漏点 | 这是本设计的核心防线 |
| 一笔没扫完 | 未扫点排在最后、原相对次序保持，状态栏报剩余数 | 分多笔继续扫即可 |
| 重复扫同一处 | 已计号的点被跳过，不产生重复 | 由 `strokeSwept` / `isSwept` 保证 |
| 扫过之后又用橡皮擦删点 | `sweptOrder` 被清空，顺序回落到 `extraction` | §4.3 的失效规则；用户会看到曲线「变回原样」，属预期 |
| 曲线点数 > 5000 | 序号不再逐点绘制（现有 `drawSequenceNumbers` 的上限） | 既有行为，非本工具引入 |
| 曲线 `< 2` 个点 | 无折线可排，工具无实际作用 | 建议状态栏提示「点数不足」 |

---

## 8. 测试计划

延续项目既有做法：**算法与几何进 `GDCoreTests`，端到端进 `--selftest`**。

### 8.1 `GDCoreTests`（纯逻辑，无需 UI）

| 用例 | 断言 |
|---|---|
| 全量扫过后顺序正确 | 合成一条解析曲线（如正弦），乱序喂进去，按正确路径扫，`orderedPoints` 与真值点序一致 |
| 部分扫过 | 未扫点精确出现在序列**尾部**，且保持原相对次序 |
| 重复扫 | 重复扫过的点不产生重复序号，总数不变 |
| 越界 / 重复下标 | 手工构造脏 `sweptOrder`，`orderedPoints` 不崩溃、不丢点、不重复 |
| 失效规则 | `append` / `replacePoints` 之后 `sweptOrder` 为 nil |
| 切换无损 | `.swept` ↔ `.extraction` 来回切，`points` 原始数组不变 |
| Codable 兼容 | 不含 `sweptOrder` 键的旧 JSON 能解码，得到 nil |

### 8.2 `--selftest`（端到端）

| 用例 | 断言 |
|---|---|
| 快速扫不漏点 | 构造一段长曲线，用**跨越大半张图的两点**模拟快速甩动，扫完后所有点都被计号 |
| 慢速扫顺序正确 | 沿曲线逐步移动，结果顺序与解析真值一致 |
| 圈大小换算 | 在**非 1:1 缩放**下构造，验证圈刷覆盖范围按 `viewScale` 正确换算（与橡皮擦同一处坑，§5.1 已有先例） |
| 进度计数 | 扫到一半时状态栏数字与已计号点数一致 |
| 工具栏宽度 | 若采纳 §6 的 ②，重跑宽度自检必须仍然 ≤ 1440pt |

> 「非 1:1 缩放下的圈换算」是本项目**已经踩过一次的坑**（`viewScale` 的注释专门为此而写），
> 新工具沿用同一套换算，测试也照抄同一组断言。

---

## 9. 分期落地建议

| 阶段 | 内容 | 可独立验收 |
|---|---|---|
| **P1 核心** | `sweptOrder` 模型 + `PointOrder.swept` + 圈刷采集算法 + 菜单入口 | 能扫、能排对、能切回原序 |
| **P2 反馈** | 进度文案、已扫/未扫分组着色、橙色圈刷 | 扫的过程可读 |
| **P3 测试** | §8 的单测与自检补全 | 全部绿 |
| **P4 打磨** | 网格索引（仅当实测卡顿）、是否要工具栏位（§6 ②） | 性能与布局 |

**P1 就能独立用起来**，建议先做到 P1 + P3，再决定要不要继续。

---

## 10. 拍板结果

| # | 问题 | 决定 |
|---|---|---|
| 1 | 入口形态 | **只走菜单**（§6 ①）。工具栏实测只剩 10pt 余量，不动。 |
| 2 | 快捷键 | **⌘B** |
| 3 | 圈刷配色 | **橙色**（橡皮擦红、重新选点框是橙但形态完全不同，不冲突） |
| 4 | 未扫点的处理 | **排到末尾、保留原相对次序** —— 它的乱跳折线正是「还没扫完」的提示 |

---

## 11. 落地记录（2026-10-01）

P1–P3 已实现，P4（网格索引、工具栏位）按 §9 的结论暂不做。

### 11.1 实际改动

| 文件 | 改动 |
|---|---|
| `GDCore/SweepReorder.swift` | **新增**。圈刷算法：`sweep` 按半径×0.5 重采样路径，`capture` 按运动方向投影排序，`resolve` 输出「已扫前缀 + 未扫尾段」 |
| `GDCore/PointOrder.swift` | 加 `case swept`（`displayName = "重排顺序"`）；`apply(to:)` 对它返回原序并注明原因 |
| `GDCore/CurveLine.swift` | 加 `sweptOrder: [Int]?`、`orderedPointsAndSweptCount`、`sweptPointCount`；`ProjectState` 加 `removePoints` / `removePoint` / `recordSweep` / `clearSweep`，并由私有 `invalidateSweep` 统一执行失效规则 |
| `GraphDiggerApp/CanvasView.swift` | `ToolMode` 加 `.reorder`；鼠标三分支；`beginReorderStroke` / `extendReorderStroke` / `recordSweep`；`drawToolRing` 支持橙色；`drawCurve` 拆分已扫/未扫；`erase` 与 `redigitize` **改走 `ProjectState`** |
| `GraphDiggerApp/AppDelegate.swift` | 菜单 `Operations ▸ Reorder Points by Sweep (点重排)` ⌘B、`Clear Reorder (清除重排)`；`refreshUI` 输出重排进度并按 `ToolMode.usesRing` 决定圈控件显隐；`canvas(_:didChangeRingRadius:)` 走专门通道更新读数（滑块连续上报，不能每次都重建数据面板） |
| `GraphDiggerApp/ToolbarView.swift` | `InfoBarView` 的 `− ⌀NN +` 换成 `半径 NN + 滑槽`（`updateRing` / `setRingControlVisible`）；`InfoBarDelegate` 由 delta 改为绝对值 |
| `GraphDiggerApp/SidebarView.swift` | `diagnosisText` 补 `.swept` 分支（写明已扫 n/N 点，并说明可切回还原） |

### 11.2 与设计稿的偏差

1. **扫过即自动切到「重排顺序」**（设计稿 §2.5 只说「可切回」）。理由：扫本身就是选择这个顺序的动作，若还要用户再去下拉框点一次，手势在第一秒看起来像没反应。`sweptOrder` 仍然独立保存，切回「取点顺序」一样无损。
2. **橡皮擦 / 重新选点改走 `ProjectState`**。设计稿 §4.3 列为「建议」，这里做了：`removePoints(of:where:)` 与 `removePoint(of:at:)` 让「改点」和「失效重排」成为一个动作，不再靠调用方记得。
3. **`SweepReorder` 独立成 GDCore 文件**，而不是把算法写在 `CanvasView` 里——纯逻辑可单测，界面层只做事件换算，与项目既有的分层一致。

### 11.3 验证

| 项 | 结果 |
|---|---|
| `swift build` | 通过，无警告 |
| `swift test` | **76/76**（原 57 + 新增 19：`SweepReorderTests` 17 例、`PointOrderTests` 2 例） |
| `--selftest` | **83 项全绿**，新增 2 项端到端：<br>「点重排按圈刷扫过的先后重新编号 — 98/98 点 · 正向保序、反向得逆序」<br>「点重排圈按缩放换算到图像 — 缩放 44% · 编号 9 点(不换算只会编号 5)」 |

关键用例的设计意图：

- **`testASingleFastDragStillCatchesEveryPointItPassedOver`** —— 一次事件跨 200px、圈只有 18pt 半径。去掉路径重采样就会漏掉中间所有点，这是整个设计赖以成立的那一条。
- **`testACatchIsOrderedByTravelNotByDistanceFromTheCentre`** —— 取两个点，让「离圆心近」和「先被扫到」给出**不同**答案，断言后者胜出。
- **`testSweepingRecoversAnArcThatSortingByXCannot`** —— 左半圆弧按列取点，先证明按 X 排序还原不了，再证明扫能还原。
- **自检的「反向得逆序」** —— 同一条曲线正向扫保序、反向扫得逆序，走真实鼠标事件；若编号退回成任何「与路径无关」的规则，这一条立刻红。

