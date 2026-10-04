# GetData 复刻软件 · 开发环境与架构设计文档

| 项目 | 内容 |
|---|---|
| 文档版本 | v1.0 |
| 日期 | 2026-09-30 |
| 关联文档 | 《GetData复刻_功能需求文档.md》(FRD v1.0) |
| 范围 | 本机开发环境盘点、技术栈选型结论、软件架构设计 |

---

## 1. 开发环境盘点(实测,2026-09-30)

### 1.1 硬件与系统

| 项 | 值 |
|---|---|
| 机型芯片 | Apple **M5**,arm64 |
| 系统 | macOS **26.6**(Build 25G72) |
| 开发目录 | ~/DataBase/ClaudeCode/Project/GraphDigger(2026-10-01 从 ~/DataBase/ClaudeCode-Project/session-20260929 迁入) |

### 1.2 已装工具链

| 工具 | 状态 | 说明 |
|---|---|---|
| Swift | ✅ **6.3.3**(arm64-apple-macosx26.0) | 语言级可用 |
| Xcode.app | ❌ **未安装** | ⚠️ 只有 Command Line Tools(`/Library/Developer/CommandLineTools`),无 IDE、无模拟器管理;**`xcodebuild` 不可用 → SPM 构建裸 SwiftUI app 会失败**(链接阶段需要 Xcode 平台框架) |
| CLT SDK | ✅ macOS SDK 27.0 | C/clang、基础框架可用 |
| Git | ✅ 2.50.1 | |
| Python(base) | ✅ 3.14.6(/opt/anaconda3) | base 环境含 PyQt6 / PySide6 / Pillow / numpy / openpyxl / tkinter |
| conda envs | ppt-master、py3820 | 按既有约定:**新环境建在项目目录内,绝不动 anaconda base** |
| Node / npm | ❌ 未安装(也无 nvm) | Electron/Tauri-web 需另装 |
| Rust(cargo/rustc) | ❌ 未安装 | Tauri 路线需另装 |
| CMake / Qt(qmake) | ❌ 未装(brew 亦未安装) | C++/Qt 路线成本最高 |
| 代码签名身份 | ❌ 0 valid identities | 本地分发用 **ad-hoc 签名**即可;对外发布需 Apple Developer 证书 + 公证 |

### 1.3 网络可达性(实测)

| 源 | 状态 |
|---|---|
| pypi.org | ✅ 200 |
| github.com | ✅ 200 |
| static.crates.io | ⚠️ 403(直连受限;装 Rust 时建议配 rsproxy/tuna 镜像) |
| Anthropic WebSearch/WebFetch | ❌ 会话内被策略拦截(curl 正常,调研继续走 curl) |

### 1.4 关键结论:SwiftUI 在本机"可写不可编"

本机缺 Xcode.app 是当前最大约束。补齐方式二选一:
- **A.** App Store 安装 Xcode(约 12 GB 磁盘)+ `sudo xcode-select -s`;一次性投入,之后原生路线全通;
- **B.** 绕开 AppKit/SwiftUI,用不需要 Xcode 的 GUI 工具包(Python Qt / Tk),零新增大件。

本文档据此给出三条候选栈对比,并给出推荐。

---

## 2. 技术栈选型

### 2.1 需求回顾(FRD §6 差异化、NFR-3 体积、用户画像)

- 安装包小巧(目标 ≤ 20 MB,越小越好;对标原版 1 MB);
- macOS 原生体验优先(单机科研工具,无需跨平台首版);
- 图像解码(JPEG/PNG/TIFF/BMP/PCX)、像素掩膜、缩放平移画布、表格编辑、多格式导出(CSV/XLSX/TXT/XML/DXF/EPS)、工作区持久化;
- 数据本地化(NFR-6),离线可用。

### 2.2 候选方案对比

| 维度 | ① Swift + AppKit(SPM executable)| ② Python + PySide6(pyinstaller)| ③ Tauri 2(Rust + 前端)| ④ Python + Tkinter(stdlib)|
|---|---|---|---|---|
| 产出形态 | 手写 bundle 的 .app | .app(冻结解释器) | .app(webview+rust) | .app(冻结解释器) |
| 安装包体积(实测量级) | **≈ 5–15 MB,最小** | ≈ 40–150 MB(Qt 框架整包) | ≈ 10–25 MB(依赖前端产物)| **≈ 15–35 MB**(Tcl/Tk 随 python 冻结)|
| 本机可行性 | ⚠️ 需先装 Xcode.app(~12GB)才能编译 AppKit 应用 | ✅ 立即可用(PySide6 已在 base;新建项目环境 pip 安装即可) | ❌ 需装 Rust(crates 网络受限)+ Node + 前端工具链 | ✅ 立即可用(tkinter stdlib,**零第三方依赖**)|
| 运行性能(M×N 像素掩膜、万点渲染) | ✅✅ 原生最快 | ✅ numpy 向量化足够 | ✅ 算法在 Rust,但 IPC 传点阵麻烦 | ⚠️ 纯 Python 慢 → **必须配 PIL/numpy 或 C 扩展**|
| UI 现代度 | AppKit 原生观感良好(比 SwiftUI 略旧但够用) | 原生风格部件,成熟 | 任意 web UI,最漂亮 | 偏朴素,科研工具可接受 |
| 图像生态 | CoreGraphics/ImageIO(TIFF/BMP/PNG ✅;PCX ❌ 需自解)| Pillow 全格式(含 PCX ✅) | image crate(rustpcx 小众) | Pillow(需装,base 已有)|
| 导出生态 | 全部手写(CoreText/CoreData 反而重) | openpyxl(XLSX ✅)/自写 CSV、XML、DXF、EPS 简单文本格式 | 同左,均需手写 | 同 ②(库完全复用) |
| 撤销栈/表格编辑 | NSTableView ✅ | QTableView + 模型层 ✅ | 前端实现 ✅ | ttk.Treeview ⚠️ 单元格编辑要自己封装 |
| 打包复杂度 | 低(spm build + 脚本组 bundle)| 中(pyinstaller spec)| 高(三套工具链冷启动)| 低 |
| 长期演进(未来 Win/Linux)| 差(仅 mac) | ✅ 好 | ✅ 最好 | ✅ 好 |

### 2.3 推荐决策

> **首选:① Swift + AppKit,前提是先装 Xcode.app;若不想动 12 GB 磁盘,则退回 ④ Python + Tkinter + Pillow/numpy 作为第一阶段实现。**

理由:
1. 体量与体验双达标——原生二进制 5–15 MB、无运行时、CoreGraphics 解码快,是最贴合"小巧实用"定位的形态;M5 + Swift 6.3 编译器已就位,只欠 Xcode 一步;
2. 本项目生命周期不短(算法打磨期长),原生语言在图像处理热路径上的迭代效率明显高于"Python 调 C"混合体;
3. ②PySide6 体积代价太大(Qt 框架整包 40 MB 起步),与 NFR-3 冲突,仅当拒绝安装 Xcode 且嫌 Tk 简陋时才选;
4. ③Tauri 在当前机器上冷启动成本最高(Rust crates 网络受限 + 无 node),排除出第一版;若产品日后要出网页版再引入。

**分阶段落地(两轨并行兼容):**

- **Phase 0(本周可做)**:用现有 Python 环境写"算法参考实现"——颜色掩膜、网格采点、线跟踪、标定映射,拿合成图定基准精度(呼应 FRD 风险 #2)。此代码不进产品,只做规格验证。
- **Phase 1**:装 Xcode 后以 Swift/AppKit 按本文档架构实现 MVP(FRD M1);PCX 解码等长尾格式按需补。
- 若 Phase 1 中途受阻(如 Xcode 安装审批久),Phase 0 的算法层可直接平移进 ④Tkinter 壳先行自用,不浪费。

### 2.4 Phase 1 前置准备清单(Swift 路线)

```bash
# 1) 安装 Xcode(App Store 或 developer.apple.com),完成后:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# 2) 同意许可
sudo xcodebuild -license accept
# 3) 验证
xcodebuild -version && swift --version
```
其余无需安装:Git 已有;SPM 随工具链;签名走 ad-hoc(`codesign -s -`)。

---

## 3. 软件架构设计(按 Swift/AppKit 主轨;模块划分对 ④ 同样适用)

### 3.1 分层总览

```
┌─────────────────────────────────────────────────────┐
│ Presentation(AppKit Views / Controls)              │
│  ImageCanvasView · ScaleOverlay · PointLayer         │
│  Toolbar(File/Operations/View 三区,对齐 FR-10.2)   │
│  DataTableView · CalibrationSheet · ExportSheet      │
├─────────────────────────────────────────────────────┤
│ Application(State & Commands)                       │
│  WorkspaceController(工程文件读写/自动快照)          │
│  CommandStack(撤销/重做,FR-6.5)                    │
│  ToolMode 状态机(select/capture/eraser/reorder/…)    │
│  SelectionModel(当前线、选中点集)                    │
├─────────────────────────────────────────────────────┤
│ Domain(纯逻辑,零 UIKit/AppKit 依赖)                 │
│  CalibrationMap(FR-2.x:线性/log 双向映射)           │
│  ColorMask(FR-4.x:前景/背景取样→二值掩膜)           │
│  Digitizer(FR-5.x:AreaGridDigitizer / TraceLine     │
│            Digitizer;FR-6.x 手动点操作)             │
│  LineModel / PointSeries(FR-3.x 多线管理)           │
│  Exporters(FR-9.x:CSV/TXT/XLSX/XML/DXF/EPS/剪贴板)  │
├─────────────────────────────────────────────────────┤
│ Infrastructure                                         │
│  ImageIO(CodingProvider 协议:PNG/JPEG/TIFF/BMP,    │
│           PCX 为可选插件式实现)                       │
│  FileServices(NSSavePanel/OpenPanel,沙盒友好)       │
│  WorkspaceStore(JSONCodable,.gddproj)                │
└─────────────────────────────────────────────────────┘
```

依赖方向自上而下单向:Presentation → Application → Domain ← Infrastructure。Domain 无任何系统框架引用,是算法单元测试与"Phase 0 Python 参考实现对拍"的锚点。

### 3.2 核心数据模型

```swift
struct PixelPoint { var x, y: Double }        // 像素坐标(亚像素,网格中位可为 .5)
struct DataPoint  { var x, y: Double }        // 数据坐标

struct AxisCalibration {
    var minPixel, maxPixel: Double
    var minValue, maxValue: Double
    var isLogarithmic: Bool                   // FR-2.3,X/Y 独立
}

struct CalibrationMap {                        // FR-2.4 双向映射,纯函数
    var xAxis: AxisCalibration
    var yAxis: AxisCalibration
    func toData(_ p: PixelPoint) -> DataPoint
    func toPixel(_ d: DataPoint) -> PixelPoint
}

struct CurveLine: Identifiable {               // FR-3.x
    var id: UUID
    var name: String
    var color: RGBA
    var points: [PixelPoint]                   // 存储态=像素序,显示时经 map 变换
}

struct ProjectState {                          // FR-8.x,JSONCodable
    var imageRef: ImageSource                  // 内嵌 data 或相对路径
    var calibration: CalibrationMap
    var lines: [CurveLine]
    var activeLineID: UUID
    var viewState: ViewState                   // 缩放平移,供恢复现场
}
```

要点:**点序列统一存像素坐标**,导出的数据坐标 = `map.toData(p)` 即时计算。好处:重新标定(改 4 点数值)后所有提取结果自动更新,这正是原版的痛点之一。

### 3.3 关键流程时序

**标定(FR-2.x)**
```
进入 SetScaleTool → 依次点取 Xmin/Xmax/Ymin/Ymax(每点弹数值输入)
→ CalibrationConfirmSheet(可改任一值/勾 log)→ 生成 CalibrationMap
→ 画布叠加轴标注释
```

**区域数字化(FR-5.2)**
```
拖框选矩形 → AreaGridDigitizer(rect, dx, rotation?)
→ ColorMask.apply(image.rect) → 每格取前景像素中位 → [PixelPoint]
→ AddPointsCommand 入撤销栈 → PointLayer 即时渲染
→ 切 Eraser 清理离群点
```

**自动跟踪(FR-5.1)**
```
点击起点 → TraceLineDigitizer:沿掩膜 8-邻域游走,
断点按局部切向预测桥接(≤k px),遇分叉暂停询问 → 有序点序列
```

**导出(FR-9.x)**
```
Exporter.export(lines.map{ $0.points.map(map.toData) }, format)
→ CSV/TXT:手写序列化;XLSX:minizip+OOXML 模板(或轻量库);
DXF/EPS:文本格式直接拼;剪贴板:NSPasteboard .string(TSV)
```

### 3.4 热路径算法与性能预算(NFR-2:4000×3000px、万点 <1s)

| 环节 | 做法 |
|---|---|
| 解码 | ImageIO 一次;内部持有 `UInt8 RGB` 位图缓冲(灰度图转 L 通道) |
| 掩膜 | `(color − lineColor)` 加权欧氏距离 ≤ tolerance → `[Bool]`;一次 O(N),后续复用;SIMD 加速(Accelerate/vImage)|
| 网格采点 | 按行扫描矩形内格子,格内统计前景像素质心 → O(面积),单次交互内完成 |
| 渲染 | PointLayer 用 CAShapeLayer 批量 path;>5k 点时降采样显示、导出全量;缩放平移走 layer transform 不重绘 |
| 大图为底 | NSImageView 替身:自绘视图 + tile 缓存,避免整图拉伸模糊 |

### 3.5 撤销系统设计(FR-6.5)

命令模式:`protocol EditCommand { apply(); undo() }`,覆盖 AddPoints / RemovePoints(Eraser 批删)/ MovePoint / InsertPoint / ReorderPoints / ChangeCalibration / ChangeLineColor / AddLine / DeleteLine。WorkspaceController 持 `CommandStack`(容量 ≥50,合并连续同类拖动为一条)。

### 3.6 工具状态机(FR-6/ToolMode)

```
idle ─openImage→ browsing ⇄(toolbar)⇄ scaleTool / eyedropperLine /
eyedropperBg / gridDigitize / traceDigitize / capture / eraser / reorder
每个工具声明:(a) 接受的鼠标事件 (b) 是否消费滚动缩放 (c) 光标
```

### 3.7 工程文件格式(FR-8.3)

`.gddproj`(名称待定)= JSON:`project.json` + 图片内嵌 base64(≤10 MB 图)或 `assets/` 相对路径;版本字段 `schemaVersion` 预留迁移。自动快照:N 分钟/关键操作后写入容器内 `AutoRecover/`(NFR-4)。

### 3.8 模块 ↔ FRD 需求追踪表

| 架构模块 | 覆盖需求 |
|---|---|
| CodingProvider | FR-1.1 |
| ImageCanvasView/ViewState | FR-1.2/1.3 |
| ScaleTool+CalibrationMap | FR-2.1–2.5 |
| CurveLine/SelectionModel | FR-3.x |
| ColorMask | FR-4.1–4.3 |
| AreaGridDigitizer / TraceLineDigitizer | FR-5.x |
| ToolMode+EditCommands | FR-6.x |
| DataTableView | FR-7.2 |
| WorkspaceStore | FR-8.x |
| Exporters | FR-9.x |
| MainMenu(xib/swift 菜单) | FR-10.2/10.3 |

### 3.9 测试策略

1. **Domain 单测(Swift Testing)**:CalibrationMap 往返精度、log 边界;合成图(已知解析曲线渲染成 PNG)→ 掩膜→网格采点 → 误差 ≤0.5% 断言 —— 同时回答 FRD 风险 #2(基准数据集:程序生成,免费且真值精确);
2. **Phase 0 Python 对拍**:同一张合成图跑参考实现与 Swift 实现,比对点集;
3. UI 冒烟:截图回归跳过(首版手工);
4. 验收清单按 FRD §8 M1 列表逐项打勾。

### 3.10 打包与分发(macOS)

- SPM 构建 executable → 脚本组装 `.app` 骨架(`Contents/MacOS/`、`Info.plist`、`PkgInfo`、icon);
- ad-hoc 签名 `codesign -s - --force --deep`(本机 0 证书可用;Gatekeeper 下首开需右键打开或 `xattr -d com.apple.quarantine`);
- 对外发布再上 Developer ID + notarytool 公证;
- DMG(dmgbuild/hdiutil)分发,成品预期 5–15 MB —— 满足 NFR-3。

### 3.11 目录结构草案

```
GraphDigger/                    # 产品名待定,勿沿用 "GetData" 商标风险名
├── Package.swift
├── Sources/
│   ├── GDApp/            # main、AppDelegate、MainMenu、打包脚本
│   ├── GDViews/          # Canvas、Layers、Sheets、Table
│   ├── GDCore/           # Domain 全部(无 AppKit import)
│   └── GDExport/         # Exporters(含 XLSX zip 写出)
├── Tests/GDCoreTests/    # 精度基准用例
├── scripts/make_app.sh   # bundle + adhoc sign + dmg
└── docs/                 # 本两份文档
```

---

## 4. 开放问题(待用户拍板)

1. **是否现在安装 Xcode.app(~12 GB)** —— 决定走主轨(Swift)还是过渡轨(Tkinter);
2. 产品命名(法律查重,"GetData" 不建议直接使用);
3. XLSX 导出:自写 OOXML(zip+xml)vs 引一个纯 Swift 小库 —— 倾向自写,MVP 先 CSV/TXT 顶替;
4. 首版是否需要 DXF/EPS(P1/P2,可后置)。
