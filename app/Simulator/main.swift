import Cocoa
import UniformTypeIdentifiers

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// ============================================================
// 游戏配置（运行时从 bundle 内 config.plist / faq.txt 读取）
// 每个游戏对应 app/targets/<game>/ 一份配置，打包时拷进 Resources。
// ============================================================
/// 单个游戏的全部差异项，逻辑代码不含硬编码，值全部来自此结构。
struct GameConfig: Decodable {
    let appIdentifier: String    // App Support 目录名 + 进程匹配
    let feverDownloadURL: String // 发烧平台安装器下载地址
    let gameId: Int              // 发烧平台数字游戏 ID
    let gameKey: String          // 透传标识："yysls" / "ywzh"
    let title: String            // 主界面游戏标题
    let windowTitle: String      // 窗口标题
    let aboutTitle: String       // 关于菜单标题
    let volumeSkipName: String   // 扫描外接设备时跳过的自身 DMG 卷名
    let qqGroup: String          // QQ 群号
    let productName: String      // 产物名（打包脚本用，App 内不消费）
}

/// 配置加载失败：明确弹窗报错并退出，不静默使用默认值。
func fatalConfigError(_ msg: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "配置加载失败"
    alert.informativeText = msg
    alert.alertStyle = .critical
    alert.addButton(withTitle: "退出")
    alert.runModal()
    exit(1)
}

/// 定位 target 资源：优先 App bundle Resources；开发态回落到源码 app/targets/<target>/。
/// 开发态目标由环境变量 SIM_DEV_TARGET 指定，缺省 yanyun。
/// 打包后一律走 bundle 分支；fallback 仅用于裸跑二进制调试，按常见 CWD 逐一探测。
func targetResourceURL(_ name: String, _ ext: String) -> URL? {
    if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
    let target = ProcessInfo.processInfo.environment["SIM_DEV_TARGET"] ?? "yanyun"
    let rel = "targets/\(target)/\(name).\(ext)"
    let cwd = FileManager.default.currentDirectoryPath
    var candidates = [
        "\(cwd)/app/\(rel)",   // 从仓库根运行
        "\(cwd)/\(rel)",       // 从 app/ 目录运行
    ]
    // 相对可执行文件所在目录再兜底探测（../../app/targets 等）
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    candidates.append(execDir.deletingLastPathComponent().appendingPathComponent("app/\(rel)").path)
    for p in candidates where FileManager.default.fileExists(atPath: p) {
        return URL(fileURLWithPath: p)
    }
    return nil
}

let cfg: GameConfig = {
    guard let url = targetResourceURL("config", "plist") else {
        fatalConfigError("找不到 config.plist，App 资源可能损坏。")
    }
    do {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(GameConfig.self, from: data)
    } catch {
        fatalConfigError("解析 config.plist 失败：\(error)")
    }
}()

/// FAQ 全文（bundle 内 faq.txt）
let faqText: String = {
    if let url = targetResourceURL("faq", "txt"),
       let s = try? String(contentsOf: url, encoding: .utf8) {
        return s
    }
    return "暂无内容。"
}()

// ============================================================
// 标准菜单栏（支持 ⌘Q 退出、⌘H 隐藏、⌘M 最小化）
// ============================================================
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: cfg.aboutTitle, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
hideOthers.keyEquivalentModifierMask = [.command, .option]
appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "窗口")
windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowMenuItem.submenu = windowMenu

app.mainMenu = mainMenu

// ============================================================
// 全局配置
// ============================================================
let appIdentifier = cfg.appIdentifier  // App Support 目录名，也用于进程匹配
let feverDownloadURL = cfg.feverDownloadURL

/// 是否启用 Wine 详细日志调试模式
/// true  → WINEDEBUG 输出详细日志到 Logs/wine_debug.log
/// false → WINEDEBUG=-all（抑制所有输出，正式发布用）
let debugWineLog = false

/// DXMT 崩溃复现调试开关（仅排障用，正式发布必须为 false）
/// true  → 强制该游戏走 DXMT(backend=2) + 打开详细 Wine/DXMT 日志，用于对照复现
/// false → 按 winecompat 正常决定后端（ywzh 走 dxmt，纯虚崩溃已由 cxcompatdb 热修复）
let debugDxmt = false

/// 生成固定 18×18 画布的 SF Symbol 模板图标
/// 使用 drawingHandler 方式，Retina 下自动按屏幕分辨率渲染（不模糊），且所有图标等宽对齐
func makeSymbolIcon(_ symbolName: String, pointSize: CGFloat = 13) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    let canvasSize = NSSize(width: 18, height: 18)
    let canvas = NSImage(size: canvasSize, flipped: false) { rect in
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
           let configured = img.withSymbolConfiguration(config) {
            // 居中绘制，取整避免次像素偏移导致模糊
            let dx = floor((rect.width - configured.size.width) / 2)
            let dy = floor((rect.height - configured.size.height) / 2)
            configured.draw(in: NSRect(x: dx, y: dy,
                                       width: configured.size.width,
                                       height: configured.size.height))
        }
        return true
    }
    canvas.isTemplate = true
    return canvas
}

// ============================================================
// 路径工具
// ============================================================
let fm = FileManager.default
let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent(appIdentifier)
let winePrefix = appSupport.appendingPathComponent("wine-prefix")
// GPTK（Metal 原生 D3D 渲染组件）公共存放位置，与 wine-prefix 同级。
// 用户自行放置，不随 App 分发；存在时 ywzh 等 D3D12 游戏优先走 Metal 直译路径。
let gptkDir = appSupport.appendingPathComponent("gptk")
let logsDir = appSupport.appendingPathComponent("Logs")
let installerPath = appSupport.appendingPathComponent("fever-installer.exe")
let feverGamesDir = winePrefix.appendingPathComponent("drive_c/Program Files/FeverGames")
let launcherName = "FeverGamesLauncher.exe"
let managedProcessRegistry = ManagedProcessRegistry(
    fileURL: appSupport.appendingPathComponent(".managed-processes.json")
)

func ensureDirs() {
    try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
    try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    // 清理上次强制退出遗留的临时脚本（_run_*.sh / _launch_*.sh）
    if let files = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil) {
        for f in files where (f.lastPathComponent.hasPrefix("_run_") || f.lastPathComponent.hasPrefix("_launch_")) && f.pathExtension == "sh" {
            try? fm.removeItem(at: f)
        }
    }
}
ensureDirs()

// debug 模式：每次 App 启动清空 Wine 日志，避免多次运行内容叠加
// （旧写法用 forWritingAtPath 不 truncate，短内容覆盖后留旧尾巴，日志混叠不可信）
if debugWineLog {
    try? Data().write(to: logsDir.appendingPathComponent("wine_debug.log"))
}

// ============================================================
// 日志
// ============================================================
let logFile = logsDir.appendingPathComponent("simulator.log")
func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if fm.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

// Wine 路径（从 app bundle Resources 取，fallback 到绝对路径）
let wineRoot: String? = {
    // 优先：Bundle Resources
    if let r = Bundle.main.resourceURL?.appendingPathComponent("wine-release") {
        let p = r.path
        if fm.fileExists(atPath: p) { print("WINE: bundle path OK: \(p)"); return p }
    }
    // fallback: Contents/Resources 硬编码
    if let exePath = Bundle.main.executableURL {
        let resPath = exePath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/wine-release").path
        if fm.fileExists(atPath: resPath) { print("WINE: fallback path OK: \(resPath)"); return resPath }
    }
    // fallback2: 相对于可执行文件的上级目录查找
    let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let devPath = execDir.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("output/wine-release").path
    if fm.fileExists(atPath: devPath) { return devPath }
    return nil
}()

let wineBinary: String? = wineRoot.map { $0 + "/lib/wine/x86_64-unix/wine" }
let wineserverBinary: String? = wineRoot.map { $0 + "/bin/wineserver" }
let legacyDxmtD3D11SHA256: String? = wineRoot.flatMap {
    RuntimeIntegrity.sha256(
        ofFile: URL(fileURLWithPath: $0)
            .appendingPathComponent("lib/dxmt/x86_64-windows/d3d11.dll")
    )
}

func processSnapshot() -> [ProcessRecord] {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,command="]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return ProcessScope.parsePSOutput(output)
    } catch {
        log("读取进程列表失败: \(error)")
        return []
    }
}

func scopedProcessIDs(matching processName: String? = nil) -> Set<Int32> {
    let records = processSnapshot()
    let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
    let registeredRoots = managedProcessRegistry.activePIDs { pid in
        guard kill(pid, 0) == 0 || errno == EPERM,
              let record = byPID[pid],
              let runtime = wineRoot, !runtime.isEmpty else {
            return false
        }
        // A persisted PID is trusted only while it still points into this runtime
        // or prefix. This prevents PID reuse from ever targeting an unrelated app.
        return record.command.contains(runtime) ||
            record.command.contains(winePrefix.path) ||
            record.command.contains(appIdentifier)
    }
    if let processName {
        return ProcessScope.matchingProcessIDs(
            processName,
            in: records,
            prefixPath: winePrefix.path,
            appIdentifier: appIdentifier,
            registeredRootPIDs: registeredRoots
        )
    }
    return ProcessScope.scopedProcessIDs(
        in: records,
        prefixPath: winePrefix.path,
        appIdentifier: appIdentifier,
        registeredRootPIDs: registeredRoots
    )
}

// ============================================================
// 启动状态（用 didSet 驱动 UI 切换）
// ============================================================
enum State: Equatable {
    case idle, loading, failed(String)
    static func == (lhs: State, rhs: State) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
var state: State = .idle {
    didSet {
        DispatchQueue.main.async {
            switch state {
            case .idle:
                hideLoading()
                errorView?.removeFromSuperview()
                errorView = nil
                setGameIconsEnabled(true)
            case .loading:
                errorView?.removeFromSuperview()
                errorView = nil
                hideGameHints()          // 双击启动后提示文案一次性消失
                setGameIconsEnabled(false)
            case .failed(let msg):
                hideLoading()
                showErrorUI(msg)
                setGameIconsEnabled(true) // 图标恢复可点，但提示文案不重现
            }
        }
    }
}

// 检测当前 WINEPREFIX 下的游戏平台 GUI（不匹配其他 Wine/模拟器实例）。
func isFeverRunning() -> Bool {
    !scopedProcessIDs(matching: "FeverGamesWeb").isEmpty
}

// ============================================================
// 游戏模型（数据驱动多图标）
// ============================================================
/// 主界面展示的游戏。每个 App 只对应一个游戏（配置来自 config.plist），
/// 通过 URL scheme（fevergames://mygame/?gameId=<id>）进入对应游戏。
struct Game {
    let id: String            // 透传标识："yysls" / "ywzh"
    let title: String         // 标题文案
    let iconResource: String  // App Resources 中的图标文件名（不含后缀）
    let gameId: Int           // 发烧平台数字游戏 ID
    /// 传给 launcher 的启动 URL
    var launchURL: String { "fevergames://mygame/?gameId=\(gameId)" }
}
let games = [
    Game(id: cfg.gameKey, title: cfg.title, iconResource: "game-icon", gameId: cfg.gameId),
]

// ============================================================
// 窗口
// ============================================================
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 450),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = cfg.windowTitle
window.center()
window.backgroundColor = NSColor.windowBackgroundColor
let cv = window.contentView!
cv.wantsLayer = true

// ============================================================
// 左侧：游戏图标 + 双击（左上角位置）
// ============================================================
// 数据驱动生成游戏图标：图标 + 标题 + 提示文案 + 双击手势
var gameIconViews: [NSImageView] = []
var gameDescLabels: [NSTextField] = []
var gameGestures: [NSClickGestureRecognizer] = []
var gameClickers: [ClickHandler] = []   // 持有 handler，避免被释放

let iconSize: CGFloat = 92
let iconGap: CGFloat = 40
let firstIconX: CGFloat = 42
let iconY: CGFloat = 450 - 26 - iconSize

for (index, game) in games.enumerated() {
    let iconX = firstIconX + CGFloat(index) * (iconSize + iconGap)
    let iconCenterX = iconX + iconSize / 2

    // 图标
    let iconView = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.wantsLayer = true
    iconView.layer?.cornerRadius = 12
    iconView.layer?.masksToBounds = true
    // 从 App Bundle Resources 加载游戏图标
    if let logoPath = Bundle.main.path(forResource: game.iconResource, ofType: "png"),
       let logoImage = NSImage(contentsOfFile: logoPath) {
        iconView.image = logoImage
    } else {
        // fallback: 从源码 targets 目录加载（开发调试用）
        if let devURL = targetResourceURL(game.iconResource, "png"),
           let img = NSImage(contentsOfFile: devURL.path) {
            iconView.image = img
        } else {
            iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
        }
    }
    cv.addSubview(iconView)

    // 标题
    let titleLabel = NSTextField(labelWithString: game.title)
    titleLabel.frame = NSRect(x: iconX, y: iconY - 30, width: iconSize, height: 22)
    titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
    titleLabel.textColor = .labelColor
    titleLabel.alignment = .center
    cv.addSubview(titleLabel)

    // 提示文案（每个图标下方各一行，双击后一次性消失）
    let descLabel = NSTextField(labelWithString: "双击游戏图标启动游戏")
    descLabel.frame = NSRect(x: iconCenterX - 65, y: iconY - 52, width: 130, height: 16)
    descLabel.font = NSFont.systemFont(ofSize: 11)
    descLabel.textColor = .secondaryLabelColor
    descLabel.alignment = .center
    cv.addSubview(descLabel)

    // 双击手势（各自绑定，handler 持有对应 Game）
    let clicker = ClickHandler(game: game, iconView: iconView)
    let gesture = NSClickGestureRecognizer(target: clicker, action: #selector(ClickHandler.doubleClick))
    gesture.numberOfClicksRequired = 2
    iconView.addGestureRecognizer(gesture)

    gameIconViews.append(iconView)
    gameDescLabels.append(descLabel)
    gameGestures.append(gesture)
    gameClickers.append(clicker)
}

/// 隐藏所有游戏提示文案（双击启动后一次性消失，不再重现）
func hideGameHints() {
    for label in gameDescLabels { label.isHidden = true }
}

/// loading 期间禁用/恢复游戏图标（视觉降透明度 + 手势响应开关）
func setGameIconsEnabled(_ enabled: Bool) {
    for view in gameIconViews { view.alphaValue = enabled ? 1.0 : 0.4 }
    for gesture in gameGestures { gesture.isEnabled = enabled }
}

// ============================================================
// 双击手势 + 残影爆开动画
// ============================================================

/// 播放 macOS 风格的"残影爆开"动画（双击图标时的视觉反馈）
func playGhostExpandAnimation(on view: NSImageView) {
    guard let image = view.image,
          let parentView = view.superview else { return }
    
    // 1. 原图标短暂暗化（闪烁感）
    let darkenLayer = CALayer()
    darkenLayer.frame = view.frame
    darkenLayer.cornerRadius = 12
    darkenLayer.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
    parentView.layer?.addSublayer(darkenLayer)
    
    // 2. 创建残影层
    let ghostLayer = CALayer()
    ghostLayer.frame = view.frame
    ghostLayer.cornerRadius = 12
    ghostLayer.masksToBounds = true
    ghostLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    ghostLayer.contentsGravity = .resizeAspectFill
    ghostLayer.opacity = 0.6
    parentView.layer?.addSublayer(ghostLayer)
    
    // 3. 残影爆开动画：放大 + 淡出
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.25)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    CATransaction.setCompletionBlock {
        ghostLayer.removeFromSuperlayer()
        darkenLayer.removeFromSuperlayer()
    }
    
    // 放大动画（从 1 → 3.5）
    let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
    scaleAnim.fromValue = 1.0
    scaleAnim.toValue = 3.5
    scaleAnim.fillMode = .forwards
    scaleAnim.isRemovedOnCompletion = false
    ghostLayer.add(scaleAnim, forKey: "scale")
    
    // 淡出动画（从 0.6 → 0）
    let fadeAnim = CABasicAnimation(keyPath: "opacity")
    fadeAnim.fromValue = 0.6
    fadeAnim.toValue = 0.0
    fadeAnim.fillMode = .forwards
    fadeAnim.isRemovedOnCompletion = false
    ghostLayer.add(fadeAnim, forKey: "fade")
    
    // 暗化层也淡出
    let darkenFade = CABasicAnimation(keyPath: "opacity")
    darkenFade.fromValue = 1.0
    darkenFade.toValue = 0.0
    darkenFade.beginTime = CACurrentMediaTime() + 0.15
    darkenFade.duration = 0.1
    darkenFade.fillMode = .forwards
    darkenFade.isRemovedOnCompletion = false
    darkenLayer.add(darkenFade, forKey: "fade")
    
    CATransaction.commit()
}

class ClickHandler: NSObject {
    let game: Game
    let iconView: NSImageView
    init(game: Game, iconView: NSImageView) {
        self.game = game
        self.iconView = iconView
    }
    @objc func doubleClick(_ sender: NSClickGestureRecognizer) {
        switch state {
        case .idle, .failed:
            // 播放残影爆开动画（作用在被点击的图标上）
            playGhostExpandAnimation(on: iconView)

            // 如果游戏平台已经在运行，直接拉起窗口（不新开 wine 进程）
            if isFeverRunning() {
                log("游戏平台已在运行，尝试拉起窗口: \(game.id)")
                bringFeverToFront(game)
            } else {
                startLaunch(game)
            }
        case .loading:
            break  // loading 中忽略
        }
    }
}

// ============================================================
// 右侧：设置面板
// ============================================================
let settingsPanel = NSView(frame: NSRect(x: 427, y: 0, width: 213, height: 450))
settingsPanel.wantsLayer = true
settingsPanel.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.05).cgColor
let border = CALayer()
border.frame = NSRect(x: 0, y: 0, width: 1, height: 450)
border.backgroundColor = NSColor.separatorColor.cgColor
settingsPanel.layer?.addSublayer(border)

let headerLabel = NSTextField(labelWithString: "高级设置")
headerLabel.frame = NSRect(x: 18, y: 422, width: 150, height: 20)
headerLabel.font = NSFont.boldSystemFont(ofSize: 11)
headerLabel.textColor = .tertiaryLabelColor
settingsPanel.addSubview(headerLabel)

// Wine配置按钮已隐藏（暂时不需要）

// 常见问题
class FAQHandler: NSObject {
    @objc func handleFAQ() {
        let alert = NSAlert()
        alert.messageText = "常见问题"
        alert.informativeText = faqText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}
let faqHandler = FAQHandler()
let faqBtn = NSButton(frame: NSRect(x: 8, y: 388, width: 197, height: 28))
faqBtn.title = ""
faqBtn.isBordered = false
faqBtn.alignment = .left
faqBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
faqBtn.target = faqHandler
faqBtn.action = #selector(FAQHandler.handleFAQ)
faqBtn.image = makeSymbolIcon("questionmark.circle")
faqBtn.imagePosition = .imageLeft
faqBtn.contentTintColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua]) == .darkAqua
        ? NSColor(white: 0.75, alpha: 1.0)
        : NSColor(white: 0.2, alpha: 1.0)
}
faqBtn.title = " 常见问题"
settingsPanel.addSubview(faqBtn)

class QuitHandler: NSObject {
    @objc func handleQuit() {
        let alert = NSAlert()
        alert.messageText = "强制退出"
        alert.informativeText = "确定要强制退出游戏吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            forceQuitWine()
            state = .idle
        }
    }
}
let quitHandler = QuitHandler()
let quitBtn = NSButton(frame: NSRect(x: 8, y: 356, width: 197, height: 28))
quitBtn.title = ""
quitBtn.isBordered = false
quitBtn.alignment = .left
quitBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
quitBtn.target = quitHandler
quitBtn.action = #selector(QuitHandler.handleQuit)
// 用系统垃圾桶图标，直接设置 SF Symbol（避免 canvas 中转导致 Retina 模糊）
quitBtn.image = makeSymbolIcon("trash")
quitBtn.imagePosition = .imageLeft
// 深色模式下图标用浅灰色，正常模式保持默认黑色
quitBtn.contentTintColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua]) == .darkAqua
        ? NSColor(white: 0.75, alpha: 1.0)
        : NSColor(white: 0.2, alpha: 1.0)
}
quitBtn.title = " 强制退出游戏"
settingsPanel.addSubview(quitBtn)

// 重置模拟器环境
class ResetHandler: NSObject {
    @objc func handleReset() {
        let alert = NSAlert()
        alert.messageText = "重置模拟器环境"
        alert.informativeText = "确定要删除 Wine prefix 和安装器吗？\n这将清除所有数据，下次启动将重新初始化。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            forceQuitWine()
            try? fm.removeItem(at: winePrefix)
            try? fm.removeItem(at: installerPath)
            try? fm.removeItem(at: appSupport.appendingPathComponent(".fever_installed"))
            state = .idle
            let alert2 = NSAlert()
            alert2.messageText = "已重置"
            alert2.informativeText = "模拟器环境已清除，下次启动将重新初始化。"
            alert2.alertStyle = .informational
            alert2.addButton(withTitle: "确定")
            alert2.runModal()
        }
    }
}
let resetHandler = ResetHandler()
let resetBtn = NSButton(frame: NSRect(x: 8, y: 324, width: 197, height: 28))
resetBtn.title = ""
resetBtn.isBordered = false
resetBtn.alignment = .left
resetBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
resetBtn.target = resetHandler
resetBtn.action = #selector(ResetHandler.handleReset)
resetBtn.image = makeSymbolIcon("gearshape")
resetBtn.imagePosition = .imageLeft
// 深色模式下图标用浅灰色，正常模式保持默认黑色
resetBtn.contentTintColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua]) == .darkAqua
        ? NSColor(white: 0.75, alpha: 1.0)
        : NSColor(white: 0.2, alpha: 1.0)
}
resetBtn.title = " 重置模拟器环境"
settingsPanel.addSubview(resetBtn)

// 加入交流群
class QQGroupHandler: NSObject {
    let qqGroupNumber: String = cfg.qqGroup

    @objc func handleQQGroup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qqGroupNumber, forType: .string)
        let alert = NSAlert()
        alert.messageText = "已复制群号"
        alert.informativeText = "QQ群号已复制到剪贴板"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}
let qqGroupHandler = QQGroupHandler()
let qqGroupBtn = NSButton(frame: NSRect(x: 8, y: 292, width: 197, height: 28))
qqGroupBtn.isBordered = false
qqGroupBtn.alignment = .left
qqGroupBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
qqGroupBtn.target = qqGroupHandler
qqGroupBtn.action = #selector(QQGroupHandler.handleQQGroup)
qqGroupBtn.image = makeSymbolIcon("message")
qqGroupBtn.imagePosition = .imageLeft
qqGroupBtn.contentTintColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua]) == .darkAqua
        ? NSColor(white: 0.75, alpha: 1.0)
        : NSColor(white: 0.2, alpha: 1.0)
}
qqGroupBtn.title = " QQ交流群：\(qqGroupHandler.qqGroupNumber)"
settingsPanel.addSubview(qqGroupBtn)

class DiagnosticsHandler: NSObject {
    @objc func handleExport() {
        presentDiagnosticsExport()
    }
}
let diagnosticsHandler = DiagnosticsHandler()
let diagnosticsBtn = NSButton(frame: NSRect(x: 8, y: 260, width: 197, height: 28))
diagnosticsBtn.isBordered = false
diagnosticsBtn.alignment = .left
diagnosticsBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
diagnosticsBtn.target = diagnosticsHandler
diagnosticsBtn.action = #selector(DiagnosticsHandler.handleExport)
diagnosticsBtn.image = makeSymbolIcon("square.and.arrow.up")
diagnosticsBtn.imagePosition = .imageLeft
diagnosticsBtn.contentTintColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua]) == .darkAqua
        ? NSColor(white: 0.75, alpha: 1.0)
        : NSColor(white: 0.2, alpha: 1.0)
}
diagnosticsBtn.title = " 导出诊断报告"
settingsPanel.addSubview(diagnosticsBtn)
cv.addSubview(settingsPanel)

// ============================================================
// 左下角说明文字
// ============================================================
let noteLabel = NSTextField(wrappingLabelWithString: "说明：\n- 建议 macOS 15 及以上，内存 16GB+，芯片 M2 及以上。不支持 Intel。\n- 如果弹窗无法点击，关掉其他应用释放内存后重试。\n- 更多问题请查看【常见问题】模块。")
noteLabel.frame = NSRect(x: 26, y: 6, width: 391, height: 100)
noteLabel.font = NSFont.systemFont(ofSize: 12)
noteLabel.textColor = .secondaryLabelColor
cv.addSubview(noteLabel)

// ============================================================
// Loading 遮罩（毛玻璃 + spinner）
// ============================================================
class LoadingOverlay: NSView {
    let label: NSTextField
    let spinner: NSProgressIndicator
    
    override init(frame: NSRect) {
        label = NSTextField(labelWithString: "加载中...")
        spinner = NSProgressIndicator()
        super.init(frame: frame)
        wantsLayer = true
        
        // 毛玻璃效果（backdrop-blur）
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        
        // Spinner（系统原生 12 元素渐变旋转器）
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: frame.width/2 - 16, y: frame.height/2 + 8, width: 32, height: 32)
        addSubview(spinner)
        spinner.startAnimation(nil)
        
        // 加载文案（默认字体）
        label.font = NSFont.systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: frame.width/2 - 200, y: frame.height/2 - 25, width: 400, height: 20)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateText(_ t: String) { DispatchQueue.main.async { self.label.stringValue = t } }
}

var loadingView: LoadingOverlay?
func showLoading(_ msg: String) {
    DispatchQueue.main.async {
        loadingView?.removeFromSuperview()
        let lv = LoadingOverlay(frame: cv.bounds)
        cv.addSubview(lv)
        loadingView = lv
        lv.updateText(msg)
    }
}
func hideLoading() {
    DispatchQueue.main.async {
        loadingView?.removeFromSuperview()
        loadingView = nil
    }
}

// deactivateWindow 已废弃（操作窗口层级会影响 Wine 窗口）

// ============================================================
// 错误提示 + 重试
// ============================================================
var errorView: NSView?
func showError(_ msg: String) {
    log("错误: \(msg)")
    DispatchQueue.main.async {
        state = .idle
        let alert = NSAlert()
        alert.messageText = "出错了"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }
}
func showErrorUI(_ msg: String) {
    // 已改为 NSAlert 弹窗，此方法保留为空实现
}

// ============================================================
// Shell 执行
// ============================================================
func shell(_ exe: String, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval? = nil) -> (Int32, String) {
    // 如果有自定义 env，写临时脚本执行（绕过 SIP 的 DYLD 剥离）
    // 如果没有 env，直接用 Process 执行系统命令。
    let p = Process()
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    
    if let env, !env.isEmpty {
        // 写唯一临时脚本
        let scriptPath = appSupport.appendingPathComponent("_run_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 1000...9999)).sh")
        var scriptLines = ["#!/bin/bash"]
        for (k, v) in env {
            // 对值进行单引号转义，避免路径中的空格和特殊字符问题
            let escaped = v.replacingOccurrences(of: "'", with: "'\\''")
            scriptLines.append("export \(k)='\(escaped)'")
        }
        let quotedArgs = args.map { arg -> String in
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }.joined(separator: " ")
        scriptLines.append("exec '\(exe)' \(quotedArgs)")
        let scriptContent = scriptLines.joined(separator: "\n") + "\n"
        try? scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        log("[shell] 脚本路径: \(scriptPath.path)")
        p.executableURL = scriptPath
        
        // 注意：不能用 defer 删脚本，必须等进程执行完再删
        do {
            try p.run()
            if let to = timeout {
                let sem = DispatchSemaphore(value: 0)
                var result: (Int32, String) = (-1, "timeout")
                DispatchQueue.global().async {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    p.waitUntilExit()
                    result = (p.terminationStatus, out)
                    sem.signal()
                }
                if sem.wait(timeout: .now() + to) == .timedOut {
                    p.terminate()
                    try? fm.removeItem(at: scriptPath)
                    return (-1, "timeout")
                }
                try? fm.removeItem(at: scriptPath)
                return result
            } else {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                try? fm.removeItem(at: scriptPath)
                return (p.terminationStatus, out)
            }
        } catch {
            try? fm.removeItem(at: scriptPath)
            return (-1, error.localizedDescription)
        }
    } else {
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
    }
    
    do {
        try p.run()
        if let to = timeout {
            let sem = DispatchSemaphore(value: 0)
            var result: (Int32, String) = (-1, "timeout")
            DispatchQueue.global().async {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                result = (p.terminationStatus, out)
                sem.signal()
            }
            if sem.wait(timeout: .now() + to) == .timedOut {
                p.terminate()
                return (-1, "timeout")
            }
            return result
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (p.terminationStatus, out)
        }
    } catch {
        return (-1, error.localizedDescription)
    }
}

/// 启动后台 Wine 进程（不等待退出）
func launchWineBackground(
    exe: String,
    args: [String],
    env: [String: String],
    workDir: String? = nil,
    role: String = "wine"
) -> Process? {
    let scriptPath = appSupport.appendingPathComponent("_launch_\(Int.random(in: 10000...99999)).sh")
    var scriptLines = ["#!/bin/bash"]
    for (k, v) in env {
        let escaped = v.replacingOccurrences(of: "'", with: "'\\''")
        scriptLines.append("export \(k)='\(escaped)'")
    }
    if let wd = workDir {
        let escaped = wd.replacingOccurrences(of: "'", with: "'\\''")
        scriptLines.append("cd '\(escaped)'")
    }
    let quotedArgs = args.map { arg -> String in
        let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }.joined(separator: " ")
    let exeEscaped = exe.replacingOccurrences(of: "'", with: "'\\''")
    scriptLines.append("exec '\(exeEscaped)' \(quotedArgs)")
    let scriptContent = scriptLines.joined(separator: "\n") + "\n"
    try? scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    
    let p = Process()
    p.executableURL = scriptPath
    p.standardOutput = FileHandle.nullDevice
    if debugWineLog {
        // debug 模式：Wine stderr 追加写入 wine_debug.log
        // 用 O_APPEND 保证多个后台进程（wineserver -p 与游戏进程并发）写入时
        // 由内核原子追加到文件末尾，不会互相覆盖；文件在 App 启动时已清空一次。
        let wineDebugLogPath = logsDir.appendingPathComponent("wine_debug.log").path
        let fd = open(wineDebugLogPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            p.standardError = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        } else {
            p.standardError = FileHandle.nullDevice
        }
    } else {
        p.standardError = FileHandle.nullDevice
    }
    // 设置 terminationHandler 回收子进程（避免僵尸进程）
    p.terminationHandler = { process in
        managedProcessRegistry.remove(pid: process.processIdentifier)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            try? fm.removeItem(at: scriptPath)
        }
    }
    do {
        try p.run()
        managedProcessRegistry.record(pid: p.processIdentifier, role: role)
        if !p.isRunning {
            managedProcessRegistry.remove(pid: p.processIdentifier)
        }
        return p
    } catch {
        try? fm.removeItem(at: scriptPath)
        return nil
    }
}

// ============================================================
// Wine 环境管理
// ============================================================
func verifyWine() -> Bool {
    log("验证 Wine: wineRoot=\(wineRoot ?? "nil"), wineBinary=\(wineBinary ?? "nil")")
    guard let w = wineBinary else {
        showError("Wine 运行时不可用")
        return false
    }
    guard fm.fileExists(atPath: w) else { showError("Wine 二进制不存在: \(w)"); return false }
    let (code, ver) = shell(w, ["--version"])
    log("wine --version: code=\(code), ver=\(ver.trimmingCharacters(in: .whitespacesAndNewlines))")
    guard code == 0 else { showError("Wine --version 失败, 路径: \(w)"); return false }
    return true
}

func markerMatches(_ url: URL, expected: String) -> Bool {
    guard let value = try? String(contentsOf: url, encoding: .utf8) else {
        return false
    }
    return value == expected
}

func checkPrefix() -> Bool {
    let readyMarker = winePrefix.appendingPathComponent(".prefix_ready")
    let systemReg = winePrefix.appendingPathComponent("system.reg")
    let userReg = winePrefix.appendingPathComponent("user.reg")
    if markerMatches(readyMarker, expected: "prefix-v2"),
       fm.fileExists(atPath: systemReg.path),
       fm.fileExists(atPath: userReg.path) {
        return true
    }

    // 只移除失效的成功标记，绝不自动删除已有 prefix 或游戏文件。
    if fm.fileExists(atPath: readyMarker.path) {
        do {
            try fm.removeItem(at: readyMarker)
        } catch {
            log("无法移除失效的 prefix 标记: \(error)")
        }
    }
    if fm.fileExists(atPath: winePrefix.path) {
        log("prefix 未完成或缺少成功标记，将在原目录内修复；不会删除现有游戏数据")
    }
    return false
}

// ============================================================
// 字体族名重写(修复 web view 公告标题中文变方块)
// web view 走 DirectWrite,按字体 name 表里的“真实族名”查找;prefix 里
// 没有名为 "Microsoft YaHei"/"SimSun" 的字体,标题请求这些名字时找不到字形
// 就退回拉丁字体 → 中文豆腐块(Wine 私有的 Fonts\Replacements 与 GDI 的
// FontSubstitutes 都不被 DirectWrite 的 FindFamilyName 采用)。
// 解决:以本机 Arial Unicode 为字模,重写其 name 表为这些常用中文字体族名,
// 产出“名字对得上”的真字体。仅在用户本机用其自有字体重打标签,不随 App 分发。
// ============================================================

private struct SFNTNameRecord {
    let platformID: UInt16
    let encodingID: UInt16
    let languageID: UInt16
    let nameID: UInt16
    let bytes: Data
}

private func sfntAppendBE16(_ d: inout Data, _ v: UInt16) {
    d.append(UInt8(v >> 8)); d.append(UInt8(v & 0xff))
}
private func sfntAppendBE32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8((v >> 24) & 0xff)); d.append(UInt8((v >> 16) & 0xff))
    d.append(UInt8((v >> 8) & 0xff)); d.append(UInt8(v & 0xff))
}
private func sfntUTF16BE(_ s: String) -> Data {
    var d = Data()
    for u in s.utf16 { sfntAppendBE16(&d, u) }
    return d
}

// 计算 sfnt 表校验和:按大端 uint32 累加(不足 4 字节按 0 补齐)
private func sfntChecksum(_ bytes: [UInt8]) -> UInt32 {
    var sum: UInt32 = 0
    var i = 0
    let n = bytes.count
    while i < n {
        let b0 = UInt32(bytes[i])
        let b1 = i + 1 < n ? UInt32(bytes[i + 1]) : 0
        let b2 = i + 2 < n ? UInt32(bytes[i + 2]) : 0
        let b3 = i + 3 < n ? UInt32(bytes[i + 3]) : 0
        sum = sum &+ ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        i += 4
    }
    return sum
}

// 生成 name 表(format 0),记录须按 (platform,encoding,language,nameID) 升序
private func sfntBuildNameTable(_ records: [SFNTNameRecord]) -> Data {
    let sorted = records.sorted {
        if $0.platformID != $1.platformID { return $0.platformID < $1.platformID }
        if $0.encodingID != $1.encodingID { return $0.encodingID < $1.encodingID }
        if $0.languageID != $1.languageID { return $0.languageID < $1.languageID }
        return $0.nameID < $1.nameID
    }
    var storage = Data()
    var recBlob = Data()
    for r in sorted {
        let off = storage.count
        storage.append(r.bytes)
        sfntAppendBE16(&recBlob, r.platformID)
        sfntAppendBE16(&recBlob, r.encodingID)
        sfntAppendBE16(&recBlob, r.languageID)
        sfntAppendBE16(&recBlob, r.nameID)
        sfntAppendBE16(&recBlob, UInt16(r.bytes.count))
        sfntAppendBE16(&recBlob, UInt16(off))
    }
    var out = Data()
    sfntAppendBE16(&out, 0)                                  // format
    sfntAppendBE16(&out, UInt16(sorted.count))              // count
    sfntAppendBE16(&out, UInt16(6 + sorted.count * 12))     // stringOffset
    out.append(recBlob)
    out.append(storage)
    return out
}

// 构造某个字体族名对应的全部 name 记录:Windows 平台同时写英文(0x409)与
// 简体中文(0x804)两条族名,页面无论用英文名还是中文名都能命中;另补 Mac 平台。
private func sfntMakeNameRecords(familyEn: String, familyZh: String, ps: String) -> [SFNTNameRecord] {
    var recs: [SFNTNameRecord] = []
    func win(_ nameID: UInt16, _ s: String, _ lang: UInt16) {
        recs.append(SFNTNameRecord(platformID: 3, encodingID: 1, languageID: lang, nameID: nameID, bytes: sfntUTF16BE(s)))
    }
    let en: UInt16 = 0x0409
    let zh: UInt16 = 0x0804
    win(1, familyEn, en); win(2, "Regular", en); win(3, ps, en)
    win(4, familyEn, en); win(6, ps, en); win(16, familyEn, en); win(17, "Regular", en)
    win(1, familyZh, zh); win(4, familyZh, zh); win(16, familyZh, zh)
    func mac(_ nameID: UInt16, _ s: String) {
        recs.append(SFNTNameRecord(platformID: 1, encodingID: 0, languageID: 0, nameID: nameID, bytes: Data(s.utf8)))
    }
    mac(1, familyEn); mac(2, "Regular"); mac(4, familyEn); mac(6, ps)
    return recs
}

// 重建 sfnt 字体:替换 name 表、丢弃 DSIG(改后失效)、重算表目录与校验和
private func sfntRebuild(source: Data, newNameTable: Data) -> Data? {
    let src = [UInt8](source)
    guard src.count >= 12 else { return nil }
    func be16(_ o: Int) -> Int { Int(src[o]) << 8 | Int(src[o + 1]) }
    func be32(_ o: Int) -> UInt32 {
        UInt32(src[o]) << 24 | UInt32(src[o + 1]) << 16 | UInt32(src[o + 2]) << 8 | UInt32(src[o + 3])
    }
    let sfntVersion = be32(0)
    let numTables = be16(4)
    var tables: [(tag: String, data: Data)] = []
    for i in 0..<numTables {
        let ro = 12 + i * 16
        guard ro + 16 <= src.count else { return nil }
        let tag = String(bytes: src[ro..<ro + 4], encoding: .ascii) ?? ""
        let off = Int(be32(ro + 8))
        let len = Int(be32(ro + 12))
        guard off + len <= src.count else { return nil }
        tables.append((tag, Data(src[off..<off + len])))
    }
    var out: [(tag: String, data: Data)] = []
    var replaced = false
    for t in tables {
        if t.tag == "DSIG" { continue }
        if t.tag == "name" { out.append(("name", newNameTable)); replaced = true; continue }
        out.append(t)
    }
    if !replaced { out.append(("name", newNameTable)) }
    // head 表的 checkSumAdjustment 先置 0(offset 8),稍后按整文件校验和回填
    for i in out.indices where out[i].tag == "head" {
        var h = [UInt8](out[i].data)
        if h.count >= 12 { h[8] = 0; h[9] = 0; h[10] = 0; h[11] = 0 }
        out[i].data = Data(h)
    }
    out.sort { $0.tag < $1.tag }
    let n = out.count
    var offset = 12 + n * 16
    var recs: [(tag: String, checksum: UInt32, offset: Int, length: Int)] = []
    var body = Data()
    for t in out {
        let cs = sfntChecksum([UInt8](t.data))
        recs.append((t.tag, cs, offset, t.data.count))
        body.append(t.data)
        let pad = (4 - (t.data.count % 4)) % 4
        if pad > 0 { body.append(Data(repeating: 0, count: pad)) }
        offset += t.data.count + pad
    }
    var header = Data()
    sfntAppendBE32(&header, sfntVersion)
    sfntAppendBE16(&header, UInt16(n))
    var esInt = 0
    while (1 << (esInt + 1)) <= n { esInt += 1 }
    let sr = UInt16(1 << esInt) &* 16
    let rs = UInt16(n * 16) &- sr
    sfntAppendBE16(&header, sr)
    sfntAppendBE16(&header, UInt16(esInt))
    sfntAppendBE16(&header, rs)
    for r in recs {
        var tagBytes = Array(r.tag.utf8)
        while tagBytes.count < 4 { tagBytes.append(0x20) }
        header.append(contentsOf: tagBytes.prefix(4))
        sfntAppendBE32(&header, r.checksum)
        sfntAppendBE32(&header, UInt32(r.offset))
        sfntAppendBE32(&header, UInt32(r.length))
    }
    var file = [UInt8](header + body)
    let adjustment = 0xB1B0AFBA &- sfntChecksum(file)
    if let hr = recs.first(where: { $0.tag == "head" }), hr.offset + 12 <= file.count {
        let pos = hr.offset + 8
        file[pos] = UInt8((adjustment >> 24) & 0xff)
        file[pos + 1] = UInt8((adjustment >> 16) & 0xff)
        file[pos + 2] = UInt8((adjustment >> 8) & 0xff)
        file[pos + 3] = UInt8(adjustment & 0xff)
    }
    return Data(file)
}

@discardableResult
func initPrefix() -> Bool {
    guard let w = wineBinary else {
        log("prefix 初始化失败: Wine 不可用")
        return false
    }
    
    // 复制 macOS 中文字体到 Wine Fonts 目录（在 wineboot 之前放好）
    let fontsDir = winePrefix.appendingPathComponent("drive_c/windows/Fonts")
    try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)
    
    let fontSources = [
        "/System/Library/Fonts/STHeiti Light.ttc",
        "/System/Library/Fonts/STHeiti Medium.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/Library/Fonts/Arial Unicode.ttf",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Supplemental/Songti.ttc",
        "/System/Library/Fonts/Supplemental/SimSun.ttf",
        "/System/Library/Fonts/Supplemental/Microsoft Sans Serif.ttf",
    ]
    for src in fontSources {
        if fm.fileExists(atPath: src) {
            let dst = fontsDir.appendingPathComponent((src as NSString).lastPathComponent)
            if !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(atPath: src, toPath: dst.path)
                log("字体复制: \((src as NSString).lastPathComponent)")
            }
        }
    }

    // 生成“中文族名”字体(修复 web view 公告标题豆腐块,原理见 sfntRebuild 上方注释)
    // 以本机 Arial Unicode 为字模,重写 name 表为 Windows 常用中文字体族名。
    // 放在 wineboot 之前,由 wineboot 扫描 Fonts 目录时自动注册这些族名。
    let cjkModelCandidates = [
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/Library/Fonts/Arial Unicode.ttf",
    ]
    if let model = cjkModelCandidates.first(where: { fm.fileExists(atPath: $0) }),
       let modelData = try? Data(contentsOf: URL(fileURLWithPath: model)) {
        let jobs: [(en: String, zh: String, ps: String, file: String)] = [
            ("Microsoft YaHei", "微软雅黑", "MicrosoftYaHei", "msyh_fix.ttf"),
            ("SimSun", "宋体", "SimSun", "simsun_fix.ttf"),
        ]
        for j in jobs {
            let dst = fontsDir.appendingPathComponent(j.file)
            if fm.fileExists(atPath: dst.path) { continue }
            let nameTable = sfntBuildNameTable(sfntMakeNameRecords(familyEn: j.en, familyZh: j.zh, ps: j.ps))
            if let out = sfntRebuild(source: modelData, newNameTable: nameTable) {
                do { try out.write(to: dst); log("生成中文字体: \(j.en)") }
                catch { log("生成中文字体失败 \(j.en): \(error)") }
            } else {
                log("生成中文字体失败 \(j.en): sfnt 重建返回 nil")
            }
        }
    } else {
        log("未找到 Arial Unicode 字模,跳过中文字体生成(web view 中文可能显示为方块)")
    }

    // wineboot 初始化 prefix（等它真正完成）
    log("执行 wineboot -u ...")
    let (code, output) = shell(w, ["wineboot", "-u"], env: buildEnv(), timeout: 120)
    log("wineboot 完成: code=\(code), output=\(output.prefix(500))")
    guard code == 0 else {
        log("prefix 初始化失败: wineboot 返回 \(code)")
        return false
    }
    
    // wineboot 后等待 wineserver 完成初始化
    guard let ws = wineserverBinary else {
        log("prefix 初始化失败: wineserver 不可用")
        return false
    }
    log("等待 wineserver 完成 (wineserver -w)...")
    let (serverCode, serverOutput) = shell(ws, ["-w"], env: buildEnv(), timeout: 60)
    guard serverCode == 0 else {
        log("prefix 初始化失败: wineserver -w 返回 \(serverCode), \(serverOutput.prefix(300))")
        return false
    }
    log("wineserver 已完成")
    
    // 安装原生运行时库（HLSL 编译器 + VC++ 运行时）到 system32
    // 游戏运行时依赖这些原生库：内置替代实现无法编译部分着色器、且与游戏的
    // C++ 对象二进制不兼容，缺失会导致着色器编译失败或纯虚函数调用崩溃。
    guard installNativeRuntime() else {
        log("prefix 初始化失败: 原生运行时安装不完整")
        return false
    }
    
    // 写字体注册表替换
    let userReg = winePrefix.appendingPathComponent("user.reg")
    guard var regContent = try? String(contentsOf: userReg, encoding: .utf8) else {
        log("prefix 初始化失败: 无法读取 user.reg")
        return false
    }
    if !regContent.contains("[Software\\\\Wine\\\\Fonts\\\\Replacements]") {
        regContent += "\n[Software\\\\Wine\\\\Fonts\\\\Replacements]\n"
        regContent += "\"Microsoft Sans Serif\"=\"STHeiti\"\n"
        regContent += "\"MS Sans Serif\"=\"STHeiti\"\n"
        regContent += "\"MS Shell Dlg\"=\"STHeiti\"\n"
        regContent += "\"MS Shell Dlg 2\"=\"STHeiti\"\n"
        regContent += "\"SimSun\"=\"STHeiti\"\n"
        regContent += "\"NSimSun\"=\"STHeiti\"\n"
        regContent += "\"宋体\"=\"STHeiti\"\n"
        regContent += "\"微软雅黑\"=\"STHeiti\"\n"
        regContent += "\"Tahoma\"=\"STHeiti\"\n"
        do {
            try regContent.write(to: userReg, atomically: true, encoding: .utf8)
            log("字体注册表替换已写入")
        } catch {
            log("prefix 初始化失败: 无法写入 user.reg: \(error)")
            return false
        }
    }

    // 注册生成的中文字体到系统字体表。
    // 此 Wine 只自动扫描 macOS 系统字体(Z:)，不扫描 C:\windows\Fonts，故须显式登记；
    // 否则 DirectWrite(web view)按族名找不到文件，公告标题中文会显示为豆腐块。
    let fontKey = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"
    let fontRegs: [(name: String, file: String)] = [
        ("Microsoft YaHei (TrueType)", "msyh_fix.ttf"),
        ("微软雅黑 (TrueType)", "msyh_fix.ttf"),
        ("SimSun (TrueType)", "simsun_fix.ttf"),
        ("宋体 (TrueType)", "simsun_fix.ttf"),
    ]
    for reg in fontRegs where fm.fileExists(atPath: fontsDir.appendingPathComponent(reg.file).path) {
        let (regCode, regOutput) = shell(
            w,
            ["reg", "add", fontKey, "/v", reg.name, "/t", "REG_SZ",
             "/d", "C:\\windows\\Fonts\\\(reg.file)", "/f"],
            env: buildEnv()
        )
        guard regCode == 0 else {
            log("prefix 初始化失败: 字体注册 \(reg.name) 返回 \(regCode), \(regOutput.prefix(300))")
            return false
        }
    }
    log("中文字体已注册到系统字体表")

    log("字体处理完成")
    
    // 写入初始化完成标记（checkPrefix 依赖此文件判断 prefix 完整性）
    let readyMarker = winePrefix.appendingPathComponent(".prefix_ready")
    do {
        try "prefix-v2".write(to: readyMarker, atomically: true, encoding: .utf8)
        log("prefix 初始化完成标记已写入")
        return true
    } catch {
        log("prefix 初始化完成但标记写入失败: \(error)")
        return false
    }
}

// 将 wine-release/redist 下的原生运行时库拷贝进 prefix 的 system32。
// Wine 默认加载顺序对这些库优先 native，放到 system32 即可被游戏加载，
// 无需额外的 DllOverrides 注册表项。
@discardableResult
func installNativeRuntime() -> Bool {
    guard let r = wineRoot else { return false }
    let redistDir = URL(fileURLWithPath: r).appendingPathComponent("redist")
    let system32 = winePrefix.appendingPathComponent("drive_c/windows/system32")
    guard let files = try? fm.contentsOfDirectory(at: redistDir, includingPropertiesForKeys: nil) else {
        log("redist 目录不存在，无法安装原生运行时: \(redistDir.path)")
        return false
    }
    let dlls = files.filter { $0.pathExtension.lowercased() == "dll" }
    guard !dlls.isEmpty else {
        log("redist 目录没有 DLL: \(redistDir.path)")
        return false
    }
    var count = 0
    var failed = false
    for src in dlls {
        let dst = system32.appendingPathComponent(src.lastPathComponent)
        let temporary = system32.appendingPathComponent(".\(src.lastPathComponent).tmp")
        do {
            if fm.fileExists(atPath: temporary.path) {
                try fm.removeItem(at: temporary)
            }
            try fm.copyItem(at: src, to: temporary)
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.moveItem(at: temporary, to: dst)
            count += 1
        } catch {
            try? fm.removeItem(at: temporary)
            failed = true
            log("原生运行时拷贝失败 \(src.lastPathComponent): \(error)")
        }
    }
    log("原生运行时安装完成，共 \(count) 个库 → system32")
    return !failed && count == dlls.count
}

// ============================================================
// 注册 mshtml 的 TypeLib 条目
// ============================================================
// 游戏内嵌网页视图（登录 / 公告 / 活动面板，走 NtUniSdkNgWebview → ieframe →
// mshtml → wine-gecko）由 Wine 内置的 mshtml 渲染。mshtml 初始化时（dispex.c
// load_typelib）先用 LoadRegTypeLib 加载「公共」类型库 LIBID_MSHTML，失败会直接
// 返回错误导致后续网页 dispex 全部崩溃（表现为进游戏/加载场景时 WINDOWS_NATIVE_ERROR）。
//
// 公共类型库是一个独立文件 mshtml.tlb（不是内嵌在 mshtml.dll 里的私有类型库）。
// 早期打包脚本漏拷了所有 .tlb，导致 prefix 的 system32 里没有 mshtml.tlb，
// 注册表即便指向 mshtml.dll 也无效（dll 里只有私有 tlb，LIBID 不匹配 → 8002801d）。
//
// 这里做两件事，且对存量 prefix 自愈：
//   1. 若 system32 缺 mshtml.tlb，从 wine-release 拷进去；
//   2. 注册表 4 个键指向 system32\mshtml.tlb。
@discardableResult
func ensureMshtmlTypeLib(_ w: String) -> Bool {
    let marker = winePrefix.appendingPathComponent(".mshtml_typelib_fixed_v3")

    let system32 = winePrefix.appendingPathComponent("drive_c/windows/system32")
    let tlb = system32.appendingPathComponent("mshtml.tlb")
    let dll = system32.appendingPathComponent("mshtml.dll")
    if markerMatches(marker, expected: "mshtml-typelib-v3") &&
       fm.fileExists(atPath: tlb.path) {
        return true
    }
    guard fm.fileExists(atPath: dll.path) else {
        log("mshtml TypeLib 修复失败: mshtml.dll 不存在")
        return false
    }

    // 若 system32 缺 mshtml.tlb，从 wine-release 拷贝（存量 prefix 自愈的关键）
    if !fm.fileExists(atPath: tlb.path), let r = wineRoot {
        let srcTlb = URL(fileURLWithPath: r)
            .appendingPathComponent("lib/wine/x86_64-windows/mshtml.tlb")
        if fm.fileExists(atPath: srcTlb.path) {
            do {
                try fm.copyItem(at: srcTlb, to: tlb)
                log("mshtml.tlb 已补入 system32")
            } catch {
                log("mshtml TypeLib 修复失败: \(error)")
                return false
            }
        }
    }

    guard fm.fileExists(atPath: tlb.path) else {
        log("mshtml TypeLib 修复失败: mshtml.tlb 不存在")
        return false
    }
    let typelibPath = "C:\\windows\\system32\\mshtml.tlb"

    let guidKey = "HKCR\\TypeLib\\{3050F1C5-98B5-11CF-BB82-00AA00BDCE0B}\\4.0"
    let commands = [
        ["reg", "add", guidKey, "/ve", "/d", "Microsoft HTML Object Library", "/f"],
        ["reg", "add", "\(guidKey)\\0\\win64", "/ve", "/d", typelibPath, "/f"],
        ["reg", "add", "\(guidKey)\\FLAGS", "/ve", "/d", "0", "/f"],
        ["reg", "add", "\(guidKey)\\HELPDIR", "/ve", "/d", "C:\\windows\\system32", "/f"],
    ]
    for command in commands {
        let (code, output) = shell(w, command, env: buildEnv())
        guard code == 0 else {
            log("mshtml TypeLib 注册失败: code=\(code), output=\(output.prefix(300))")
            return false
        }
    }

    // 强制 wineserver 把改动落盘：默认要等客户端全退出数秒后才 flush，
    // 若这期间进程被重启会丢失，显式 -w 等它写完再继续。
    guard let ws = wineserverBinary else {
        log("mshtml TypeLib 修复失败: wineserver 不可用")
        return false
    }
    let (serverCode, serverOutput) = shell(ws, ["-w"], env: buildEnv())
    guard serverCode == 0 else {
        log("mshtml TypeLib 落盘失败: code=\(serverCode), output=\(serverOutput.prefix(300))")
        return false
    }

    do {
        try "mshtml-typelib-v3".write(to: marker, atomically: true, encoding: .utf8)
        log("mshtml TypeLib 已注册（修复内嵌网页视图崩溃，指向 \(typelibPath)）")
        return true
    } catch {
        log("mshtml TypeLib 已注册但成功标记写入失败: \(error)")
        return false
    }
}


// ============================================================
// 盘符管理：清理 DMG/App 挂载卷，保留 c:/z: + 外接设备
// ============================================================
func manageDriveLetters() {
    let dosdevices = winePrefix.appendingPathComponent("dosdevices")
    guard fm.fileExists(atPath: dosdevices.path) else { return }
    
    // 1. 删除除 c: 和 z: 之外的所有盘符映射
    if let items = try? fm.contentsOfDirectory(at: dosdevices, includingPropertiesForKeys: nil) {
        for item in items {
            let name = item.lastPathComponent.lowercased()
            // 保留 c: 和 z:
            if name == "c:" || name == "z:" { continue }
            // 删除其余盘符
            try? fm.removeItem(at: item)
        }
    }
    log("dosdevices 已清理（保留 c: 和 z:）")
    
    // 2. 扫描 /Volumes/ 找外接设备
    //    使用 URLResourceValues 元数据判断，不触发 macOS 可移除宗卷访问弹窗
    let volumesDir = URL(fileURLWithPath: "/Volumes")
    guard let volumes = try? fm.contentsOfDirectory(at: volumesDir, includingPropertiesForKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]) else {
        log("无法读取 /Volumes/ 目录")
        return
    }
    
    // 要跳过的卷名（模拟器自身 DMG）
    let appName = cfg.volumeSkipName
    // 获取启动盘挂载点（通常是 /），避免把它当外接设备
    let rootVolumePath = "/"
    
    var nextLetter: Character = "d"
    for vol in volumes.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let volName = vol.lastPathComponent
        
        // 跳过模拟器自身 DMG 挂载（名称包含 app 名）
        if volName.contains(appName) { continue }
        
        // 通过 URLResourceValues 判断卷属性（不触发权限弹窗）
        guard let resourceValues = try? vol.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsLocalKey]) else {
            continue
        }
        
        // 跳过只读卷（DMG 挂载通常是只读的）
        if resourceValues.volumeIsReadOnly == true { continue }
        
        // 跳过内部卷（启动盘等）
        if resourceValues.volumeIsInternal == true { continue }
        
        // 额外检查：解析符号链接后如果指向根目录则跳过
        let resolved = vol.resolvingSymlinksInPath().path
        if resolved == rootVolumePath { continue }
        
        // 通过了过滤的就是外接设备（U盘、移动硬盘等）
        let letter = String(nextLetter)
        let linkPath = dosdevices.appendingPathComponent("\(letter):").path
        try? fm.createSymbolicLink(atPath: linkPath, withDestinationPath: vol.path)
        log("dosdevices: \(letter): → \(vol.path)")
        
        if let scalar = nextLetter.unicodeScalars.first {
            nextLetter = Character(UnicodeScalar(scalar.value + 1)!)
            if nextLetter == "z" { nextLetter = Character(UnicodeScalar(scalar.value + 2)!) }
        }
    }
    log("盘符映射完成")
}

func checkFeverInstalled() -> Bool {
    let marker = appSupport.appendingPathComponent(".fever_installed")
    let filesAreComplete = checkFeverFiles()
    if filesAreComplete && !markerMatches(marker, expected: "fever-files-v2") {
        do {
            try "fever-files-v2".write(to: marker, atomically: true, encoding: .utf8)
            log("检测到完整游戏平台文件，已补写安装成功标记")
        } catch {
            log("游戏平台文件完整，但安装标记写入失败: \(error)")
        }
    } else if !filesAreComplete && fm.fileExists(atPath: marker.path) {
        log("安装标记存在但游戏平台文件不完整，将进入修复安装；不会删除 prefix")
    }
    log("checkFeverInstalled: marker=\(fm.fileExists(atPath: marker.path)), files=\(filesAreComplete)")
    return filesAreComplete
}

// 文件级别检测：注册表有记录 AND launcher exe 存在（用于安装等待循环）
func checkFeverFiles() -> Bool {
    let systemReg = winePrefix.appendingPathComponent("system.reg").path
    var hasReg = false
    if let content = try? String(contentsOfFile: systemReg, encoding: .utf8) {
        hasReg = content.contains("FeverGames") && content.contains("Uninstall")
    }
    var hasExe = false
    if fm.fileExists(atPath: feverGamesDir.appendingPathComponent(launcherName).path) {
        hasExe = true
    } else if let dirs = try? fm.contentsOfDirectory(at: feverGamesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        for d in dirs where d.lastPathComponent.hasPrefix("1.") {
            if fm.fileExists(atPath: d.appendingPathComponent(launcherName).path) { hasExe = true; break }
        }
    }
    return hasReg && hasExe
}

func findFeverLauncher() -> (path: String, workDir: String)? {
    let launcher = feverGamesDir.appendingPathComponent(launcherName)
    if fm.fileExists(atPath: launcher.path) { return (launcher.path, feverGamesDir.path) }
    guard let dirs = try? fm.contentsOfDirectory(at: feverGamesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
    for d in dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where d.lastPathComponent.hasPrefix("1.") {
        let lp = d.appendingPathComponent(launcherName)
        if fm.fileExists(atPath: lp.path) { return (lp.path, d.path) }
    }
    return nil
}

func buildEnv() -> [String: String] {
    // 继承全部系统环境变量（确保卷挂载、文件系统等功能正常）
    // 只覆盖/添加 Wine 专用变量
    var env = ProcessInfo.processInfo.environment
    // Wine 环境变量
    // CX_ROOT: Wine 运行时根路径（Wine 源码内部约定的环境变量名）
    if let r = wineRoot { env["CX_ROOT"] = r }
    env["WINEPREFIX"] = winePrefix.path
    if let r = wineRoot { env["DYLD_FALLBACK_LIBRARY_PATH"] = r + "/lib64" }
    if let r = wineRoot { env["GST_PLUGIN_SYSTEM_PATH"] = r + "/lib64/gstreamer-1.0" }
    env["WINEMSYNC"] = "1"
    env["ROSETTA_ADVERTISE_AVX"] = "1"
    env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
    env["QMLSCENE_DEVICE"] = "softwarecontext"
    if debugWineLog {
        env["WINEDEBUG"] = "err+all,warn+module,+loaddll,warn+ntdll,+seh"
        env["WINE_DEBUG_LOG"] = "\(logsDir.path)/wine_debug.log"
        // DXMT 自身日志：输出到 Logs 目录（每个进程一个 <exe>_d3d11.log 等）
        // 用于排查进场景时哪个 Metal/D3D11 操作失败
        env["DXMT_LOG_PATH"] = logsDir.path
        env["DXMT_LOG_LEVEL"] = "trace"
    } else {
        env["WINEDEBUG"] = "-all"
    }
    // DXMT 崩溃复现调试：仅强制 DXMT。Metal 校验层(MTL_DEBUG_LAYER/
    // MTL_SHADER_VALIDATION)极吃性能会把 launcher 拖到点不动，且那类 GPU 校验错
    // 来自平台 webview 与游戏崩溃无关，故不再开启；崩溃归属改用 vmmap 取证脚本判定。
    if debugDxmt {
        env["SIM_BACKEND_OVERRIDE"] = "2"          // DXMT（调试对照用；正常发布 debugDxmt=false 不设此变量）
    }
    if let hash = legacyDxmtD3D11SHA256 {
        // winecompat 只对精确匹配 v0.1.1 的 DXMT 二进制启用过渡期内存补丁。
        // 源码修复版的哈希不同，因此不会再被修改。
        env["SIM_DXMT_D3D11_SHA256"] = hash
    }
    // env["MTL_HUD_ENABLED"] = "1"  // 关闭 Metal FPS HUD
    // Wine 内部路径（显式设置，避免依赖相对路径 fallback）
    if let r = wineRoot {
        env["WINESERVER"] = r + "/bin/wineserver"
        env["WINELOADER"] = r + "/lib/wine/x86_64-unix/wine"
        env["WINEDLLPATH"] = r + "/lib/wine"
    }
    // GStreamer 插件缓存（避免每次启动重新扫描）
    env["GST_REGISTRY"] = appSupport.appendingPathComponent("gstreamer-1.0-registry.x86_64.bin").path
    // .NET 7/8 兼容性修复（Rosetta 下 W^X 策略冲突）
    env["DOTNET_EnableWriteXorExecute"] = "0"
    // 不设 CX_GRAPHICS_BACKEND，由 winecompat 自动决定
    // Metal 原生渲染路径（可选）：仅当公共 gptk 目录内存在该组件时才激活，
    // 否则不设置，让 d3dmetal 后端安全回落到内置 vkd3d。GPTK 不随 App 分发，
    // 存放于与 wine-prefix 同级的 gptk 目录，由用户自行放置。
    let d3dsharedPath = gptkDir.appendingPathComponent("external/libd3dshared.dylib").path
    if fm.fileExists(atPath: d3dsharedPath) {
        env["GPTK_ROOT"] = gptkDir.path
        env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dsharedPath
        // D3DMetal.framework 的 install_name 指向 /System/Library/Frameworks，
        // 系统未安装时需把 framework 搜索路径重定向到 gptk 内的副本。
        env["DYLD_FRAMEWORK_PATH"] = gptkDir.appendingPathComponent("external").path
    }
    return env
}

private func writeRedactedDiagnosticFile(from source: URL, to destination: URL, limit: Int = 20_000_000) throws {
    let data = try Data(contentsOf: source)
    let bounded = data.count > limit ? data.suffix(limit) : data[...]
    let text = String(decoding: bounded, as: UTF8.self)
    let redacted = DiagnosticRedactor.redact(
        text,
        homeDirectory: fm.homeDirectoryForCurrentUser.path
    )
    try redacted.write(to: destination, atomically: true, encoding: .utf8)
}

private func diagnosticSystemValue(_ name: String) -> String {
    let (code, output) = shell("/usr/sbin/sysctl", ["-n", name], timeout: 5)
    return code == 0 ? output.trimmingCharacters(in: .whitespacesAndNewlines) : "unavailable"
}

private func createDiagnosticsArchive(at destination: URL) throws {
    let diagnosticsRoot = appSupport.appendingPathComponent("Diagnostics")
    try fm.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)
    let staging = diagnosticsRoot.appendingPathComponent("diagnostics-\(UUID().uuidString)")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }

    for name in ["simulator.log", "wine_debug.log"] {
        let source = logsDir.appendingPathComponent(name)
        if fm.fileExists(atPath: source.path) {
            try writeRedactedDiagnosticFile(from: source, to: staging.appendingPathComponent(name))
        }
    }

    let records = processSnapshot()
    let scopedPIDs = scopedProcessIDs()
    let processText = records
        .filter { scopedPIDs.contains($0.pid) }
        .map { "pid=\($0.pid) ppid=\($0.parentPID) \($0.command)" }
        .joined(separator: "\n")
    let redactedProcesses = DiagnosticRedactor.redact(
        processText,
        homeDirectory: fm.homeDirectoryForCurrentUser.path
    )
    try redactedProcesses.write(
        to: staging.appendingPathComponent("processes.txt"),
        atomically: true,
        encoding: .utf8
    )

    var runtimeLines: [String] = []
    if let root = wineRoot {
        let criticalPaths = [
            "bin/wineserver",
            "lib/dxmt/x86_64-windows/d3d11.dll",
            "lib/wine/x86_64-unix/wine",
        ]
        for path in criticalPaths {
            let file = URL(fileURLWithPath: root).appendingPathComponent(path)
            let hash = RuntimeIntegrity.sha256(ofFile: file) ?? "unavailable"
            runtimeLines.append("\(hash)  \(path)")
        }
    }
    try runtimeLines.joined(separator: "\n").write(
        to: staging.appendingPathComponent("runtime-critical.sha256"),
        atomically: true,
        encoding: .utf8
    )
    if let manifest = Bundle.main.resourceURL?.appendingPathComponent("runtime-components.lock.json"),
       fm.fileExists(atPath: manifest.path) {
        try fm.copyItem(
            at: manifest,
            to: staging.appendingPathComponent("runtime-components.lock.json")
        )
    }

    let info = Bundle.main.infoDictionary ?? [:]
    let environment = """
    product=\(cfg.productName)
    appIdentifier=\(appIdentifier)
    appVersion=\(info["CFBundleShortVersionString"] ?? "development")
    buildVersion=\(info["CFBundleVersion"] ?? "development")
    macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)
    model=\(diagnosticSystemValue("hw.model"))
    chip=\(diagnosticSystemValue("machdep.cpu.brand_string"))
    memoryBytes=\(diagnosticSystemValue("hw.memsize"))
    prefixExists=\(fm.fileExists(atPath: winePrefix.path))
    prefixReady=\(markerMatches(winePrefix.appendingPathComponent(".prefix_ready"), expected: "prefix-v2") &&
        fm.fileExists(atPath: winePrefix.appendingPathComponent("system.reg").path) &&
        fm.fileExists(atPath: winePrefix.appendingPathComponent("user.reg").path))
    feverFilesComplete=\(checkFeverFiles())
    dxmtLegacyHash=\(legacyDxmtD3D11SHA256 ?? "unavailable")
    generatedAt=\(ISO8601DateFormatter().string(from: Date()))

    Privacy: The archive contains launcher logs, scoped process commands, runtime
    hashes and relevant recent crash reports. It does not collect registry files,
    game files, account data or Wine-prefix contents. Home paths, common tokens
    and URL query parameters are redacted on a best-effort basis.
    """
    let redactedEnvironment = DiagnosticRedactor.redact(
        environment,
        homeDirectory: fm.homeDirectoryForCurrentUser.path
    )
    try redactedEnvironment.write(
        to: staging.appendingPathComponent("environment.txt"),
        atomically: true,
        encoding: .utf8
    )

    let crashSource = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    let crashDestination = staging.appendingPathComponent("CrashReports")
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    if let reports = try? fm.contentsOfDirectory(
        at: crashSource,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
    ) {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let relevant = reports.compactMap { url -> (URL, Date)? in
            guard DiagnosticRedactor.isRelevantCrashReport(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate,
                  date >= cutoff else {
                return nil
            }
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(20)

        if !relevant.isEmpty {
            try fm.createDirectory(at: crashDestination, withIntermediateDirectories: true)
            for (source, _) in relevant {
                try writeRedactedDiagnosticFile(
                    from: source,
                    to: crashDestination.appendingPathComponent(source.lastPathComponent),
                    limit: 10_000_000
                )
            }
        }
    }

    let temporaryArchive = destination.deletingLastPathComponent().appendingPathComponent(
        ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.zip"
    )
    defer { try? fm.removeItem(at: temporaryArchive) }
    let (code, output) = shell(
        "/usr/bin/ditto",
        ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, temporaryArchive.path],
        timeout: 120
    )
    guard code == 0 else {
        throw NSError(
            domain: "DiagnosticsExport",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "压缩诊断报告失败：\(output.prefix(300))"]
        )
    }
    if fm.fileExists(atPath: destination.path) {
        _ = try fm.replaceItemAt(destination, withItemAt: temporaryArchive)
    } else {
        try fm.moveItem(at: temporaryArchive, to: destination)
    }
}

func presentDiagnosticsExport() {
    let panel = NSSavePanel()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    panel.nameFieldStringValue = "\(cfg.productName)-diagnostics-\(formatter.string(from: Date())).zip"
    panel.allowedContentTypes = [.zip]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    showLoading("正在导出诊断报告...")
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try createDiagnosticsArchive(at: destination)
            log("诊断报告已导出: \(destination.path)")
            DispatchQueue.main.async {
                hideLoading()
                let alert = NSAlert()
                alert.messageText = "诊断报告已导出"
                alert.informativeText = destination.path
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好的")
                alert.runModal()
            }
        } catch {
            DispatchQueue.main.async {
                hideLoading()
                showError("诊断报告导出失败：\(error.localizedDescription)")
            }
        }
    }
}

func forceQuitWine() {
    // Step 1: wineserver -k 由 WINEPREFIX 定位，只影响当前模拟器环境。
    if let ws = wineserverBinary {
        let (code, output) = shell(ws, ["-k"], env: buildEnv(), timeout: 15)
        log("wineserver -k: code=\(code), output=\(output.prefix(200))")
    }

    // Step 2: 仅处理由本启动器登记、属于本 prefix 或其后代的残留 PID。
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let remaining = scopedProcessIDs().filter { $0 != currentPID }
    for pid in remaining {
        if kill(pid, SIGTERM) == 0 {
            log("已向当前 prefix 进程发送 SIGTERM: pid=\(pid)")
        }
    }
    if !remaining.isEmpty {
        Thread.sleep(forTimeInterval: 1)
    }
    for pid in remaining where kill(pid, 0) == 0 || errno == EPERM {
        if kill(pid, SIGKILL) == 0 {
            log("已清理当前 prefix 残留进程: pid=\(pid)")
        }
        managedProcessRegistry.remove(pid: pid)
    }
}

// 拉起已运行的游戏平台窗口到前台（按 game 用 URL scheme 重新唤起对应游戏）
func bringFeverToFront(_ game: Game) {
    guard let w = wineBinary else { return }
    let env = buildEnv()
    
    // 重新执行启动命令：launcher 检测到已有实例会把窗口拉到前台，并切换到对应游戏
    if let (launcher, workDir) = findFeverLauncher() {
        let _ = launchWineBackground(
            exe: w,
            args: [launcher, game.launchURL],
            env: env,
            workDir: workDir,
            role: "launcher"
        )
        log("重新调用 launcher 拉起窗口: \(game.id) -> \(game.launchURL)")
    }
}

// ============================================================
// 下载管理器
// ============================================================
func downloadInstaller() {
    guard let url = URL(string: feverDownloadURL) else {
        showError("下载地址无效"); return
    }

    showLoading("正在获取下载地址...")

    // 自动识别两种下载模式（无需手动配置）：
    //   1) JSON 接口：响应体是 {"data":{"download_url":"..."}}，需解析后再下真实文件
    //   2) 直链：响应体本身就是安装器（PE 可执行），直接落盘即可
    // 正向判定 JSON：JSON 前缀固定为 '{'（跳过可能的前导空白/BOM）；
    // 不是 '{' 一律按二进制安装器处理。HTTP 4xx/5xx 已由状态码校验拦下。
    let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
        if let error {
            DispatchQueue.main.async { showError("获取下载失败: \(error.localizedDescription)") }
            return
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            DispatchQueue.main.async { showError("获取下载失败（无响应）") }
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            DispatchQueue.main.async { showError("获取下载失败（HTTP \(httpResponse.statusCode)）") }
            return
        }
        guard let src = localURL, let fh = try? FileHandle(forReadingFrom: src) else {
            DispatchQueue.main.async { showError("下载失败") }
            return
        }
        // 读开头若干字节，跳过前导空白/UTF-8 BOM，判断首个有效字符是否为 '{'
        let head = fh.readData(ofLength: 16)
        try? fh.close()
        var bytes = [UInt8](head)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)  // 去掉 UTF-8 BOM
        }
        let firstNonSpace = bytes.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        let isJSON = (firstNonSpace == 0x7B)  // '{'

        if isJSON {
            // JSON 接口模式：解析 data.download_url 后下载真实文件
            guard let data = try? Data(contentsOf: src),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let downloadURLString = dataObj["download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                let raw = String(data: (try? Data(contentsOf: src)) ?? Data(), encoding: .utf8) ?? ""
                let safe = DiagnosticRedactor.redact(raw, homeDirectory: fm.homeDirectoryForCurrentUser.path)
                log("JSON 接口解析失败: \(safe.prefix(200))")
                DispatchQueue.main.async { showError("解析下载地址失败") }
                return
            }
            let safeURL = DiagnosticRedactor.redact(
                downloadURLString,
                homeDirectory: fm.homeDirectoryForCurrentUser.path
            )
            log("检测到 JSON 接口模式，解析到安装器下载地址: \(safeURL)")
            downloadInstallerFile(from: downloadURL)
            return
        }

        // 直链模式：响应体即安装器，直接保存
        log("检测到直链模式，响应体即安装器")
        saveInstaller(from: src)
    }
    task.resume()
}

/// 第二步：下载真实的安装器文件并保存到 installerPath（JSON 接口模式使用）
func downloadInstallerFile(from url: URL) {
    DispatchQueue.main.async { showLoading("正在下载启动器...") }

    let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
        if let error {
            DispatchQueue.main.async { showError("下载失败: \(error.localizedDescription)") }
            return
        }
        guard let httpResponse = response as? HTTPURLResponse, (200..<400).contains(httpResponse.statusCode) else {
            DispatchQueue.main.async { showError("下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）") }
            return
        }
        guard let src = localURL else {
            DispatchQueue.main.async { showError("下载失败") }
            return
        }
        saveInstaller(from: src)
    }
    task.resume()
}

/// 将下载到的临时文件保存为安装器并触发安装（两种模式共用）
func saveInstaller(from src: URL) {
    try? fm.removeItem(at: installerPath)
    do {
        try fm.moveItem(at: src, to: installerPath)
        // 移除 extended attributes（防止 Gatekeeper 阻止 Wine 读取）
        let _ = shell("/usr/bin/xattr", ["-cr", installerPath.path])
        DispatchQueue.main.async { installFever() }
    } catch {
        DispatchQueue.main.async { showError("保存安装器失败") }
    }
}

/// 预启动带 SO_SNDBUF 注入的 wineserver（修复游戏平台客户端下载 IPC 死锁）
///
/// 原理：wineserverfix.so 通过 DYLD_INSERT_LIBRARIES 注入 wineserver，拦截 socket()
/// 为 loopback TCP 设置 2MB 发送缓冲，规避 IPC 首次自发自收 1MB 在
/// macOS 默认 128KB loopback 缓冲下的单线程死锁。
///
/// 注意：wineserver 是每个 WINEPREFIX 的单例。必须先杀掉旧实例，再启动带注入的常驻
/// 实例（-p），随后启动的 wine 客户端才会复用它。本函数含阻塞等待，请在后台线程调用。
func ensureInjectedWineserver() {
    guard let ws = wineserverBinary, let r = wineRoot else { return }
    let shimPath = r + "/lib/wine/x86_64-unix/wineserverfix.so"
    guard fm.fileExists(atPath: shimPath) else {
        log("wineserverfix.so 不存在，跳过注入（下载可能死锁）")
        return
    }
    // 杀掉当前 prefix 的旧 wineserver（-k 会等待其真正退出），确保带注入的新实例接管
    let _ = shell(ws, ["-k"], env: buildEnv())
    // 带 DYLD_INSERT 预启动常驻 wineserver
    var env = buildEnv()
    env["DYLD_INSERT_LIBRARIES"] = shimPath
    guard let server = launchWineBackground(
        exe: ws,
        args: ["-p"],
        env: env,
        role: "wineserver"
    ) else {
        log("带注入的 wineserver 启动失败")
        return
    }
    // 等待常驻 server 就绪，避免后续 wine 客户端抢先自行 spawn 未注入的 server
    Thread.sleep(forTimeInterval: 2)
    log("已预启动带 SNDBUF 注入的 wineserver（pid=\(server.processIdentifier)）")
}

func installFever() {
    guard wineBinary != nil else { showError("Wine 不可用"); return }
    guard fm.fileExists(atPath: installerPath.path) else { showError("安装器未找到"); return }
    showLoading("正在安装启动器...")
    // 先在后台预启动带注入的 wineserver，再执行安装（安装器会自动拉起平台）
    DispatchQueue.global().async {
        ensureInjectedWineserver()
        DispatchQueue.main.async { installFeverCore() }
    }
}

func installFeverCore() {
    guard let w = wineBinary else { showError("Wine 不可用"); return }

    // Wine 需要 Windows 路径格式来处理带空格的路径
    let winInstallerPath = "Z:" + installerPath.path.replacingOccurrences(of: "/", with: "\\")
    log("安装命令: wine \(winInstallerPath) /VERYSILENT /SUPPRESSMSGBOXES")

    let env = buildEnv()
    
    // 后台启动安装器（静默安装完成后会自动拉起平台）
    guard let _ = launchWineBackground(
        exe: w,
        args: [winInstallerPath, "/VERYSILENT", "/SUPPRESSMSGBOXES"],
        env: env,
        role: "installer"
    ) else {
        showError("安装启动失败")
        return
    }
    log("安装进程已启动")

    // 轮询等待 FeverGamesWeb 进程出现（平台启动完成的标志）
    DispatchQueue.global().async {
        let maxWait = 600
        var waited = 0
        var success = false
        
        while waited < maxWait {
            Thread.sleep(forTimeInterval: 3)
            waited += 3
            
            if checkFeverFiles() {
                success = true
                log("检测到完整游戏平台文件（等待了 \(waited) 秒），安装完成")
                break
            }
            if waited % 15 == 0 {
                log("等待安装完成... (\(waited)s)")
            }
        }
        
        guard success else {
            DispatchQueue.main.async { showError("安装超时，请重试") }
            return
        }
        
        // 安装成功，写入标记
        let marker = appSupport.appendingPathComponent(".fever_installed")
        do {
            try "fever-files-v2".write(to: marker, atomically: true, encoding: .utf8)
            log("安装标记已写入")
        } catch {
            DispatchQueue.main.async { showError("安装已完成，但无法写入成功标记：\(error.localizedDescription)") }
            return
        }
        
        // 清理安装器
        try? fm.removeItem(at: installerPath)
        
        DispatchQueue.main.async {
            hideLoading()
            state = .idle
            log("安装完成，状态 → idle")
        }
    }
}

func launchGame(_ game: Game) {
    guard wineBinary != nil else { showError("Wine 不可用"); return }
    showLoading("正在启动游戏...")
    // 先在后台预启动带注入的 wineserver，再启动游戏平台
    DispatchQueue.global().async {
        ensureInjectedWineserver()
        DispatchQueue.main.async { launchGameCore(game) }
    }
}

func launchGameCore(_ game: Game) {
    guard let w = wineBinary else { showError("Wine 不可用"); return }
    let env = buildEnv()
    
    // 策略：把 fevergames:// URL scheme 作为命令行参数传给 launcher，
    // launcher 据 gameId 直接进入对应游戏页面（燕云=37，遗忘之海=66）
    if let (launcher, workDir) = findFeverLauncher() {
        log("启动游戏 \(game.id): \(launcher) 参数: \(game.launchURL)")
        if let _ = launchWineBackground(
            exe: w,
            args: [launcher, game.launchURL],
            env: env,
            workDir: workDir,
            role: "launcher"
        ) {
            log("Launcher + URL scheme 启动命令已执行")
        } else {
            log("启动失败，尝试 fallback（无参数）")
            if !launchGameFallback(w: w, env: env) { return }
        }
    } else {
        // 没找到 launcher exe，走 fallback
        log("未找到 launcher exe，使用 fallback 方式启动")
        if !launchGameFallback(w: w, env: env) { return }
    }

    // Wine 进程已启动，主动让出前台焦点给游戏窗口
    // 延迟一小段时间让 Wine 窗口创建，然后 deactivate 自己
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        NSApp.deactivate()
    }

    // 轮询等待 FeverGamesWeb 进程出现（表示平台 GUI 真正渲染完成）
    DispatchQueue.global().async {
        let maxWait = 90 // 最多等 90 秒
        var waited = 0
        var foundWeb = false
        
        while waited < maxWait {
            Thread.sleep(forTimeInterval: 3)
            waited += 3
            
            if isFeverRunning() {
                foundWeb = true
                log("检测到 FeverGamesWeb 进程（等待了 \(waited) 秒），GUI 已渲染")
                // 额外等几秒让页面内容加载完
                Thread.sleep(forTimeInterval: 3)
                break
            }
            
            // 每 15 秒打印一次等待日志
            if waited % 15 == 0 {
                log("等待 FeverGamesWeb 进程... (\(waited)s)")
            }
        }
        
        if foundWeb {
            DispatchQueue.main.async {
                hideLoading()
                state = .idle
                log("启动完成，状态 → idle（FeverGamesWeb 已确认）")
            }
        } else {
            // 超时，检查是否有任何 FeverGames 相关进程在运行
            if !scopedProcessIDs(matching: "FeverGames").isEmpty {
                log("超时但检测到 FeverGames 进程，认为已启动")
                DispatchQueue.main.async {
                    hideLoading()
                    state = .idle
                }
            } else {
                log("超时且未检测到任何 FeverGames 进程")
                DispatchQueue.main.async {
                    showError("游戏启动超时，请重试")
                }
            }
        }
    }
}

@discardableResult
func launchGameFallback(w: String, env: [String: String]) -> Bool {
    if let (launcher, workDir) = findFeverLauncher() {
        if let _ = launchWineBackground(
            exe: w,
            args: [launcher],
            env: env,
            workDir: workDir,
            role: "launcher"
        ) {
            log("Fallback: launcher 启动命令已执行")
            return true
        } else {
            showError("启动失败")
            return false
        }
    } else {
        showError("未找到游戏启动文件")
        return false
    }
}

// ============================================================
// 启动流程
// ============================================================
func startLaunch(_ game: Game) {
    state = .loading
    // 立刻显示遮罩给出反馈：后续 wineserver 检查、注册表补写等同步操作耗时，
    // 若不先上遮罩，已初始化过的 prefix 会有一段无反馈空窗（用户以为卡死）。
    showLoading("正在准备运行环境...")
    log("===== 启动流程开始: \(game.id) =====")

    DispatchQueue.global(qos: .userInitiated).async {
        // 先杀掉残留的 wineserver（确保新环境变量生效）
        // wineserver -k 只影响当前 WINEPREFIX，不会误杀其他 Wine 环境
        if let ws = wineserverBinary {
            let _ = shell(ws, ["-k"], env: buildEnv())
        }
        Thread.sleep(forTimeInterval: 1)
        
        guard verifyWine() else { return }

        if !checkPrefix() {
            showLoading("正在初始化 Wine 环境...")
            log("初始化 prefix: \(winePrefix.path)")
            guard initPrefix() else {
                showError("Wine 环境初始化失败。现有游戏数据未被删除，请导出诊断报告后重试。")
                return
            }
            log("prefix 初始化完成")
        } else {
            log("prefix 已存在，跳过初始化")
        }

        // 补注册 mshtml TypeLib，修复登录网页窗口崩溃（新老 prefix 都覆盖，幂等）
        // 首次会跑 4 次 reg add + wineserver -w，耗时数秒；标记门控，之后秒过。
        if let w = wineBinary {
            showLoading("正在检查运行环境...")
            guard ensureMshtmlTypeLib(w) else {
                showError("运行环境注册失败。现有游戏数据未被删除，请导出诊断报告后重试。")
                return
            }
        }

        // 盘符管理：映射外接设备到 Wine 盘符
        manageDriveLetters()

        if checkFeverInstalled() {
            log("游戏平台已安装，直接启动")
            DispatchQueue.main.async { launchGame(game) }
        } else {
            log("游戏平台未安装，开始下载")
            DispatchQueue.main.async { downloadInstaller() }
        }
    }
}

// ============================================================
// App Delegate
// ============================================================
class AppDel: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ n: Notification) { forceQuitWine() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let appDel = AppDel()
app.delegate = appDel

// ============================================================
// 启动
// ============================================================
window.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)

app.run()
