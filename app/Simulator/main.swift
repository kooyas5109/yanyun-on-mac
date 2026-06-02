import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// ============================================================
// 标准菜单栏（支持 ⌘Q 退出、⌘H 隐藏、⌘M 最小化）
// ============================================================
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "关于燕云模拟器", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
let appIdentifier = "yanyun.simulator"  // App Support 目录名，也用于进程匹配
let feverDownloadURL = "https://loadingbaycn.webapp.163.com/app/v1/download_client/windows/mkt-h72-neice:netease.uubooster03pc_cps_dev/url"


/// 是否启用 Wine 详细日志调试模式
/// true  → WINEDEBUG 输出详细日志到 Logs/wine_debug.log
/// false → WINEDEBUG=-all（抑制所有输出，正式发布用）
let debugWineLog = false

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
let logsDir = appSupport.appendingPathComponent("Logs")
let installerPath = appSupport.appendingPathComponent("fever-installer.exe")
let feverGamesDir = winePrefix.appendingPathComponent("drive_c/Program Files/FeverGames")
let launcherName = "FeverGamesLauncher.exe"

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
            case .loading:
                errorView?.removeFromSuperview()
                errorView = nil
            case .failed(let msg):
                hideLoading()
                showErrorUI(msg)
            }
        }
    }
}

// 检测游戏平台 GUI 是否正在运行（只检测 Web 渲染进程，不检测后台服务）
func isFeverRunning() -> Bool {
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-f", "FeverGamesWeb"]
    let pipe = Pipe()
    pg.standardOutput = pipe
    pg.standardError = pipe
    try? pg.run()
    pg.waitUntilExit()
    return pg.terminationStatus == 0
}

// ============================================================
// 窗口
// ============================================================
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 450),
    styleMask: [.titled, .closable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "燕云模拟器"
window.center()
window.backgroundColor = NSColor.windowBackgroundColor
let cv = window.contentView!
cv.wantsLayer = true

// ============================================================
// 左侧：游戏图标 + 双击（左上角位置）
// ============================================================
let iconView = NSImageView(frame: NSRect(x: 42, y: 450 - 26 - 92, width: 92, height: 92))
iconView.imageScaling = .scaleProportionallyUpOrDown
iconView.wantsLayer = true
iconView.layer?.cornerRadius = 12
iconView.layer?.masksToBounds = true
// 从 App Bundle Resources 加载游戏图标
if let logoPath = Bundle.main.path(forResource: "logo", ofType: "png"),
   let logoImage = NSImage(contentsOfFile: logoPath) {
    iconView.image = logoImage
} else {
    // fallback: 尝试从源码目录加载（开发调试用）
    let devPath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("logo.png").path
    if let img = NSImage(contentsOfFile: devPath) {
        iconView.image = img
    } else {
        iconView.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)
    }
}
cv.addSubview(iconView)

let titleLabel = NSTextField(labelWithString: "燕云十六声")
titleLabel.frame = NSRect(x: 42, y: 450 - 26 - 92 - 30, width: 92, height: 22)
titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
titleLabel.textColor = .labelColor
titleLabel.alignment = .center
cv.addSubview(titleLabel)

let descLabel = NSTextField(labelWithString: "双击游戏图标启动游戏")
descLabel.frame = NSRect(x: 0, y: 450 - 26 - 92 - 55, width: 176, height: 16)
descLabel.font = NSFont.systemFont(ofSize: 12)
descLabel.textColor = .secondaryLabelColor
descLabel.alignment = .center
cv.addSubview(descLabel)

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
    @objc func doubleClick(_ sender: NSClickGestureRecognizer) {
        switch state {
        case .idle, .failed:
            // 播放残影爆开动画
            playGhostExpandAnimation(on: iconView)
            
            // 如果游戏平台已经在运行，直接拉起窗口（不新开 wine 进程）
            if isFeverRunning() {
                log("游戏平台已在运行，尝试拉起窗口")
                bringFeverToFront()
            } else {
                startLaunch()
            }
        case .loading:
            break  // loading 中忽略
        }
    }
}
let clicker = ClickHandler()
let gesture = NSClickGestureRecognizer(target: clicker, action: #selector(ClickHandler.doubleClick))
gesture.numberOfClicksRequired = 2
iconView.addGestureRecognizer(gesture)

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
        alert.informativeText = """
Q：Mac电脑运行燕云模拟器+燕云游戏的推荐配置是？
A：建议 macOS 15 (Sequoia) 或更高版本，内存 16GB 以上，芯片 M2 及以上。M1 可以跑但性能一般。不支持 Intel Mac。

Q：右键点击图标退出没有反应怎么办？
A：按住 option 键再右键退出，或者打开模拟器窗口选择强制退出游戏。

Q：为什么在启动器上点击安装游戏/踏入江湖后要等一会儿才开始加载？
A：Wine 翻译指令需要时间，安装或更新后尤其明显。如果主按钮无响应，退出游戏平台后重新打开再试。

Q：我在下载或更新游戏时，卡在某个步骤很久，怎么办？
A：退出游戏平台重新启动试试。如果反复出现，把 ~/Library/Application Support/yanyun.simulator/ 整个文件夹删了重来。

Q：如何彻底删除模拟器？
A：打开模拟器点"重置模拟器环境"，然后把 App 丢废纸篓。再删掉 ~/Library/Application Support/yanyun.simulator/ 文件夹就彻底干净了。如果游戏装在其他路径（比如移动硬盘），那边也要手动删。

Q：如果有更多问题，怎么向别人求助？
A：可以加模拟器上显示的 QQ 群聊。
"""
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
    let qqGroupNumber: String = "1080300274"

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
    // 如果没有 env，直接用 Process 执行（系统命令如 ps/pkill）
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
        log("[shell] 脚本内容(最后2行): \(scriptLines.suffix(2).joined(separator: " | "))")
        p.executableURL = scriptPath
        
        // 注意：不能用 defer 删脚本，必须等进程执行完再删
        do {
            try p.run()
            if let to = timeout {
                let sem = DispatchSemaphore(value: 0)
                var result: (Int32, String) = (-1, "timeout")
                DispatchQueue.global().async {
                    p.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                result = (p.terminationStatus, out)
                sem.signal()
            }
            if sem.wait(timeout: .now() + to) == .timedOut {
                p.terminate()
                return (-1, "timeout")
            }
            return result
        } else {
            p.waitUntilExit()
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    } catch {
        return (-1, error.localizedDescription)
    }
}

/// 启动后台 Wine 进程（不等待退出）
func launchWineBackground(exe: String, args: [String], env: [String: String], workDir: String? = nil) -> Process? {
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
        // debug 模式：Wine stderr 重定向到 wine_debug.log
        let wineDebugLogPath = logsDir.appendingPathComponent("wine_debug.log").path
        if let fh = FileHandle(forWritingAtPath: wineDebugLogPath) {
            p.standardError = fh
        } else {
            fm.createFile(atPath: wineDebugLogPath, contents: nil)
            p.standardError = FileHandle(forWritingAtPath: wineDebugLogPath) ?? FileHandle.nullDevice
        }
    } else {
        p.standardError = FileHandle.nullDevice
    }
    // 设置 terminationHandler 回收子进程（避免僵尸进程）
    p.terminationHandler = { _ in
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            try? fm.removeItem(at: scriptPath)
        }
    }
    do {
        try p.run()
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

func checkPrefix() -> Bool {
    // 检查 prefix 初始化完成标记（initPrefix 成功后写入）
    let readyMarker = winePrefix.appendingPathComponent(".prefix_ready").path
    if fm.fileExists(atPath: readyMarker) {
        return true
    }
    // 标记不存在，但 prefix 目录可能有残留（中断导致的不完整状态）
    let systemReg = winePrefix.appendingPathComponent("system.reg").path
    if fm.fileExists(atPath: systemReg) {
        log("prefix 不完整（system.reg 存在但 .prefix_ready 缺失），清理后重新初始化")
        try? fm.removeItem(at: winePrefix)
    }
    return false
}

func initPrefix() {
    guard let w = wineBinary else { return }
    
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
    
    // wineboot 初始化 prefix（等它真正完成）
    log("执行 wineboot -u ...")
    let (code, output) = shell(w, ["wineboot", "-u"], env: buildEnv(), timeout: 120)
    log("wineboot 完成: code=\(code), output=\(output.prefix(500))")
    
    // wineboot 后等待 wineserver 完成初始化
    if let ws = wineserverBinary {
        log("等待 wineserver 完成 (wineserver -w)...")
        shell(ws, ["-w"], env: buildEnv(), timeout: 60)
        log("wineserver 已完成")
    }
    
    // 写字体注册表替换
    let userReg = winePrefix.appendingPathComponent("user.reg")
    if var regContent = try? String(contentsOf: userReg, encoding: .utf8) {
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
            try? regContent.write(to: userReg, atomically: true, encoding: .utf8)
            log("字体注册表替换已写入")
        }
    }
    
    log("字体处理完成")
    
    // 写入初始化完成标记（checkPrefix 依赖此文件判断 prefix 完整性）
    let readyMarker = winePrefix.appendingPathComponent(".prefix_ready")
    try? "1".write(to: readyMarker, atomically: true, encoding: .utf8)
    log("prefix 初始化完成标记已写入")
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
    let appName = "燕云模拟器"
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
    let result = fm.fileExists(atPath: marker.path)
    log("checkFeverInstalled: \(result)")
    return result
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
        env["WINEDEBUG"] = "err+all,warn+module,warn+loaddll,warn+ntdll"
        env["WINE_DEBUG_LOG"] = "\(logsDir.path)/wine_debug.log"
    } else {
        env["WINEDEBUG"] = "-all"
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
    return env
}

func forceQuitWine() {
    // Step 1: 优雅退出（同步，确保 kill 信号发出）
    if let ws = wineserverBinary {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ws)
        p.arguments = ["-k"]
        p.environment = buildEnv()
        try? p.run()
        p.waitUntilExit()
    }
    // Step 2: 精准清理（异步，不阻塞 App 退出。子进程会被 launchd 接管继续执行）
    if let r = wineRoot {
        let marker = r + "/lib/wine/x86_64-unix/ntdll.so"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof 2>/dev/null | grep '\(marker)' | awk '{print $2}' | sort -u | xargs kill -9 2>/dev/null"]
        try? p.run()
    }
    // Step 3: 补充清理（异步）
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-9", "-f", appIdentifier]
    try? p.run()
}

// 拉起已运行的游戏平台窗口到前台
func bringFeverToFront() {
    guard let w = wineBinary else { return }
    let env = buildEnv()
    
    // 重新执行启动命令：launcher 检测到已有实例会把窗口拉到前台
    if let shortcutInfo = findGameShortcut(), let urlScheme = shortcutInfo.url {
        if let (launcher, workDir) = findFeverLauncher() {
            let _ = launchWineBackground(exe: w, args: [launcher, urlScheme], env: env, workDir: workDir)
            log("重新调用 launcher 拉起窗口: \(urlScheme)")
        }
    } else if let (launcher, workDir) = findFeverLauncher() {
        let _ = launchWineBackground(exe: w, args: [launcher], env: env, workDir: workDir)
        log("重新调用 launcher 拉起窗口")
    }
}

// ============================================================
// 下载管理器
// ============================================================
func downloadInstaller() {
    guard let url = URL(string: feverDownloadURL) else {
        showError("下载地址无效"); return
    }

            showLoading("正在下载启动器...")

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
        try? fm.removeItem(at: installerPath)
        do {
            try fm.moveItem(at: src, to: installerPath)
            // 移除 extended attributes（防止 Gatekeeper 阻止 Wine 读取）
            shell("/usr/bin/xattr", ["-cr", installerPath.path])
            DispatchQueue.main.async { installFever() }
        } catch {
            DispatchQueue.main.async { showError("保存安装器失败") }
        }
    }
    task.resume()
}

func installFever() {
    guard let w = wineBinary else { showError("Wine 不可用"); return }
    guard fm.fileExists(atPath: installerPath.path) else { showError("安装器未找到"); return }
            showLoading("正在安装启动器...")

    // Wine 需要 Windows 路径格式来处理带空格的路径
    let winInstallerPath = "Z:" + installerPath.path.replacingOccurrences(of: "/", with: "\\")
    log("安装命令: wine \(winInstallerPath) /VERYSILENT /SUPPRESSMSGBOXES")

    let env = buildEnv()
    
    // 后台启动安装器（静默安装完成后会自动拉起平台）
    guard let _ = launchWineBackground(exe: w, args: [winInstallerPath, "/VERYSILENT", "/SUPPRESSMSGBOXES"], env: env) else {
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
            
            let pg = Process()
            pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pg.arguments = ["-f", "FeverGamesWeb"]
            let pipe = Pipe()
            pg.standardOutput = pipe
            pg.standardError = pipe
            try? pg.run()
            pg.waitUntilExit()
            
            if pg.terminationStatus == 0 {
                success = true
                log("检测到 FeverGamesWeb 进程（等待了 \(waited) 秒），安装完成")
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
        try? "1".write(to: marker, atomically: true, encoding: .utf8)
        log("安装标记已写入")
        
        // 清理安装器
        try? fm.removeItem(at: installerPath)
        
        DispatchQueue.main.async {
            hideLoading()
            state = .idle
            log("安装完成，状态 → idle")
        }
    }
}

func findGameShortcut() -> (path: String, url: String?)? {
    // 在 prefix 桌面目录中查找快捷方式
    let desktopDirs = [
        winePrefix.appendingPathComponent("drive_c/users/crossover/Desktop"),
        winePrefix.appendingPathComponent("drive_c/users/Public/Desktop"),
    ]
    
    // 先找 .url 文件，解析出 URL scheme（用于传参给 launcher）
    for dir in desktopDirs {
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "url" {
                if let content = try? String(contentsOf: f, encoding: .utf8),
                   let urlLine = content.components(separatedBy: "\n").first(where: { $0.hasPrefix("URL=") }) {
                    let url = String(urlLine.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    log("找到桌面 .url 快捷方式: \(f.lastPathComponent), URL=\(url)")
                    return (f.path, url)
                }
            }
        }
    }
    
    // fallback: .lnk
    for dir in desktopDirs {
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "lnk" {
                log("找到桌面快捷方式(.lnk): \(f.path)")
                return (f.path, nil)
            }
        }
    }
    return nil
}

func launchGame() {
    guard let w = wineBinary else { showError("Wine 不可用"); return }
    
    showLoading("正在启动游戏...")
    let env = buildEnv()
    
    // 策略：从桌面 .url 快捷方式解析出 URL scheme，传给 FeverGamesLauncher.exe 作为参数
    // 带参数启动可以直接进入游戏页面
    if let shortcutInfo = findGameShortcut(), let urlScheme = shortcutInfo.url {
        // 方式1: 找到 launcher exe，把 URL 当命令行参数传入
        if let (launcher, workDir) = findFeverLauncher() {
            log("启动游戏: \(launcher) 参数: \(urlScheme)")
            if let _ = launchWineBackground(exe: w, args: [launcher, urlScheme], env: env, workDir: workDir) {
                log("Launcher + URL scheme 启动命令已执行")
            } else {
                log("启动失败，尝试 fallback（无 URL 参数）")
                if !launchGameFallback(w: w, env: env) { return }
            }
        } else {
            // 没找到 launcher，尝试用 start /unix .lnk
            log("未找到 launcher exe，尝试 start /unix .lnk")
            if !launchGameFallback(w: w, env: env) { return }
        }
    } else if let shortcutInfo = findGameShortcut() {
        // 只有 .lnk 没有 .url，用 start /unix 打开 .lnk
        log("启动游戏: 使用 .lnk 快捷方式: \(shortcutInfo.path)")
        if let _ = launchWineBackground(exe: w, args: ["start", "/unix", shortcutInfo.path], env: env) {
            log("Wine start /unix .lnk 启动命令已执行")
        } else {
            if !launchGameFallback(w: w, env: env) { return }
        }
    } else {
        // 没有任何快捷方式，直接运行 launcher
        log("未找到桌面快捷方式，使用 fallback 方式启动")
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
            
            // 检测 FeverGamesWeb 进程（出现表示平台 GUI 已加载）
            let pg = Process()
            pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pg.arguments = ["-f", "FeverGamesWeb"]
            let pgPipe = Pipe()
            pg.standardOutput = pgPipe
            pg.standardError = pgPipe
            try? pg.run()
            pg.waitUntilExit()
            
            if pg.terminationStatus == 0 {
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
            let pg2 = Process()
            pg2.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pg2.arguments = ["-f", "FeverGames"]
            let pg2Pipe = Pipe()
            pg2.standardOutput = pg2Pipe
            pg2.standardError = pg2Pipe
            try? pg2.run()
            pg2.waitUntilExit()
            
            if pg2.terminationStatus == 0 {
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
        if let _ = launchWineBackground(exe: w, args: [launcher], env: env, workDir: workDir) {
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
func startLaunch() {
    state = .loading
    log("===== 启动流程开始 =====")

    DispatchQueue.global(qos: .userInitiated).async {
        // 先杀掉残留的 wineserver（确保新环境变量生效）
        // wineserver -k 只影响当前 WINEPREFIX，不会误杀其他 Wine 环境
        if let ws = wineserverBinary {
            shell(ws, ["-k"], env: buildEnv())
        }
        Thread.sleep(forTimeInterval: 1)
        
        guard verifyWine() else { return }
        
        // AVX 诊断：检查环境变量是否正确设置
        let env = buildEnv()
        log("[AVX诊断] ROSETTA_ADVERTISE_AVX=\(env["ROSETTA_ADVERTISE_AVX"] ?? "未设置")")
        
        // 用 Wine 环境运行一个简单命令，确认 env 可以传递到 x86_64 进程
        if let w = wineBinary {
            let (_, envCheck) = shell("/bin/bash", ["-c", "echo ROSETTA=$ROSETTA_ADVERTISE_AVX"], env: env)
            log("[AVX诊断] bash 内 ROSETTA=\(envCheck.trimmingCharacters(in: .whitespacesAndNewlines))")
            
            // 用 check_avx 二进制直接测试 CPUID（如果存在）
            let checkAvx = "/tmp/check_avx"
            if fm.fileExists(atPath: checkAvx) {
                let (_, avxOut) = shell(checkAvx, [], env: env)
                log("[AVX诊断] check_avx 输出: \(avxOut.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        if !checkPrefix() {
            showLoading("正在初始化 Wine 环境...")
            log("初始化 prefix: \(winePrefix.path)")
            initPrefix()
            log("prefix 初始化完成")
        } else {
            log("prefix 已存在，跳过初始化")
        }

        // 盘符管理：映射外接设备到 Wine 盘符
        manageDriveLetters()

        if checkFeverInstalled() {
            log("游戏平台已安装，直接启动")
            DispatchQueue.main.async { launchGame() }
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
