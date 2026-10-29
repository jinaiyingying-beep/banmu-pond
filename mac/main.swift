// 半亩塘 · macOS 桌面锦鲤池
// 原理：每块屏幕一个无边框窗口，放在「桌面层」（壁纸之上、桌面图标之下），
// 里面是 WKWebView 渲染 web/index.html。窗口本身不接收鼠标，
// 由全局鼠标监听判断指针是否落在露出的桌面上，再把坐标转发给页面。

import Cocoa
import WebKit
import ServiceManagement

// MARK: - 设置

struct City: Codable, Equatable {
    var name: String
    var lat: Double
    var lon: Double
}

struct PondConfig: Codable {
    var name = "半亩塘"
    var fishCount = 60
    var showWidget = true
    var showTitle = true
    var fps = 60
    var timeMode = "auto"
    var weatherMode = "auto"
    var seasonMode = "auto"
    var quality = "auto"
    var city: City? = nil
    var interactive = true
    var scene = "pond"          // pond 锦鲤池 / aquarium 兰寿缸
    var tankFishCount = 9

    init() {}

    // 逐项容错解码：以后增减字段不会把旧设置整个丢掉
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PondConfig()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? d.name
        fishCount = (try? c.decodeIfPresent(Int.self, forKey: .fishCount)) ?? d.fishCount
        showWidget = (try? c.decodeIfPresent(Bool.self, forKey: .showWidget)) ?? d.showWidget
        showTitle = (try? c.decodeIfPresent(Bool.self, forKey: .showTitle)) ?? d.showTitle
        fps = (try? c.decodeIfPresent(Int.self, forKey: .fps)) ?? d.fps
        timeMode = (try? c.decodeIfPresent(String.self, forKey: .timeMode)) ?? d.timeMode
        weatherMode = (try? c.decodeIfPresent(String.self, forKey: .weatherMode)) ?? d.weatherMode
        seasonMode = (try? c.decodeIfPresent(String.self, forKey: .seasonMode)) ?? d.seasonMode
        quality = (try? c.decodeIfPresent(String.self, forKey: .quality)) ?? d.quality
        city = try? c.decodeIfPresent(City.self, forKey: .city)
        interactive = (try? c.decodeIfPresent(Bool.self, forKey: .interactive)) ?? d.interactive
        scene = (try? c.decodeIfPresent(String.self, forKey: .scene)) ?? d.scene
        tankFishCount = (try? c.decodeIfPresent(Int.self, forKey: .tankFishCount)) ?? d.tankFishCount
    }
}

enum Store {
    static let key = "pondConfig.v1"
    static func load() -> PondConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(PondConfig.self, from: data) else { return PondConfig() }
        return c
    }
    static func save(_ c: PondConfig) {
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - 窗口

final class PondWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// WKScriptMessageHandler 会被 WebKit 强引用，用弱代理避免循环引用
final class WeakMessageProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var target: AppDelegate?
    init(_ t: AppDelegate) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handleMessage(message)
    }
    // 网页绘制进程被系统回收或崩溃时，WKWebView 会变成一片白：立刻藏起来并重新加载
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        target?.webContentTerminated(webView)
    }
}

final class Pond {
    var screen: NSScreen
    let window: PondWindow
    let web: WKWebView
    var pointerInside = false
    var ready = false

    init(screen: NSScreen, pageURL: URL, proxy: WeakMessageProxy) {
        let frame = screen.frame
        let w = PondWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        // 桌面层：壁纸之上，桌面图标之下
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.36, alpha: 1)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0          // 页面第一帧画好前先不显示，避免闪一下底色

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(proxy, name: "pond")
        cfg.suppressesIncrementalRendering = true
        let wv = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        // 关掉 WKWebView 默认的白色底，没画好时露出的是窗口的池水绿，而不是整屏白
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = proxy
        w.contentView = wv

        self.screen = screen
        self.window = w
        self.web = wv
        wv.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        w.orderFrontRegardless()
    }

    func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    func close() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pond")
        window.orderOut(nil)
        window.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config = Store.load()
    var ponds: [Pond] = []
    var statusItem: NSStatusItem!
    var proxy: WeakMessageProxy!
    var pageURL: URL!
    var manualPause = false
    var autoPaused = false
    var monitors: [Any] = []
    var lastMove: CFTimeInterval = 0
    var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let url = sceneURL() else {
            let a = NSAlert()
            a.messageText = "找不到池塘页面（web 文件夹）"
            a.informativeText = "请用 build.sh 重新打包。"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        pageURL = url
        proxy = WeakMessageProxy(self)

        // 防止 App Nap 把动画降频
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Animated desktop pond")

        setupStatusItem()
        buildPonds()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(systemSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(systemSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        wnc.addObserver(self, selector: #selector(systemWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wnc.addObserver(self, selector: #selector(systemWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handleMouse(e); return e }) {
            monitors.append(l)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for m in monitors { NSEvent.removeMonitor(m) }
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
    }

    // MARK: 窗口管理

    var isTank: Bool { config.scene == "aquarium" }
    var isLagoon: Bool { config.scene == "lagoon" }

    func sceneURL() -> URL? {
        let name = isTank ? "aquarium" : isLagoon ? "lagoon" : "index"
        return Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
    }

    func buildPonds() {
        ponds.forEach { $0.close() }
        if let u = sceneURL() { pageURL = u }
        ponds = NSScreen.screens.map { Pond(screen: $0, pageURL: pageURL, proxy: proxy) }
        // 兜底：万一页面迟迟没报「准备好」，3 秒后也照样显示
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            for p in self?.ponds ?? [] where p.window.alphaValue < 1 { p.window.alphaValue = 1 }
        }
    }

    @objc func screensChanged() {
        // 稍等系统把屏幕排布稳定下来再处理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.syncScreens() }
    }

    func screenID(_ s: NSScreen) -> UInt32 {
        let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return n?.uint32Value ?? 0
    }

    /// 只有屏幕真的增减了才重建；位置/分辨率变化就原地调整窗口，避免整屏闪一下
    func syncScreens() {
        let screens = NSScreen.screens
        var sameSet = screens.count == ponds.count
        if sameSet {
            for (s, p) in zip(screens, ponds) where screenID(s) != screenID(p.screen) { sameSet = false }
        }
        if !sameSet { buildPonds(); return }
        for (s, p) in zip(screens, ponds) {
            p.screen = s
            if p.window.frame != s.frame { p.window.setFrame(s.frame, display: true) }
        }
    }

    func pushConfig(to only: Pond? = nil) {
        guard let data = try? JSONEncoder().encode(config), let json = String(data: data, encoding: .utf8) else { return }
        let targets: [Pond] = only != nil ? [only!] : ponds
        for p in targets {
            var code = "window.pond && pond.setConfig(\(json));"
            if config.city == nil { code += "window.pond && pond.setConfig({city:null});" }
            if isTank { code += "window.pond && pond.setConfig({fishCount:\(config.tankFishCount)});" }
            p.js(code)
        }
    }

    func applyPause() {
        let paused = manualPause || autoPaused
        for p in ponds { p.js("window.pond && pond.pause(\(paused))") }
    }

    @objc func systemSleep() { autoPaused = true; applyPause() }
    @objc func systemWake() { autoPaused = false; applyPause() }

    // MARK: 来自页面的消息

    func handleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            if let p = ponds.first(where: { $0.web === message.webView }) {
                p.ready = true
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    p.window.animator().alphaValue = 1
                }
                pushConfig(to: p)
                if manualPause || autoPaused { p.js("window.pond && pond.pause(true)") }
            }
        case "cityResult":
            if (body["ok"] as? Bool) == true,
               let c = body["city"] as? [String: Any],
               let name = c["name"] as? String,
               let lat = (c["lat"] as? NSNumber)?.doubleValue,
               let lon = (c["lon"] as? NSNumber)?.doubleValue {
                config.city = City(name: name, lat: lat, lon: lon)
                Store.save(config)
                pushConfig()
                let detail = (body["detail"] as? String) ?? ""
                info("天气城市已设为「\(name)」", detail.isEmpty ? "" : detail)
            } else {
                let q = (body["query"] as? String) ?? ""
                if body["error"] != nil {
                    info("天气服务连不上", "请检查网络后再试一次。")
                } else {
                    info("没找到「\(q)」", "换个写法试试，比如中文全称或拼音。")
                }
            }
        default:
            break
        }
    }

    func webContentTerminated(_ webView: WKWebView) {
        guard let p = ponds.first(where: { $0.web === webView }) else { return }
        p.ready = false
        p.window.alphaValue = 0
        webView.reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if p.window.alphaValue < 1 { p.window.alphaValue = 1 }
        }
    }

    // MARK: 鼠标转发

    func handleMouse(_ e: NSEvent) {
        guard config.interactive, !manualPause else { return }
        let kind: String
        switch e.type {
        case .leftMouseDown: kind = "down"
        case .mouseMoved, .leftMouseDragged: kind = "move"
        default: return
        }
        let now = CACurrentMediaTime()
        if kind == "move" {
            if now - lastMove < 1.0 / 60.0 { return }
            lastMove = now
        }
        let loc = NSEvent.mouseLocation
        let onDesktop = desktopExposed(at: loc, now: now, fresh: kind == "down")
        for p in ponds {
            let f = p.screen.frame
            if onDesktop && f.contains(loc) {
                let x = loc.x - f.minX, y = f.maxY - loc.y
                p.js("window.pond && pond.pointer(\(x),\(y),'\(kind)')")
                p.pointerInside = true
            } else if p.pointerInside {
                p.pointerInside = false
                p.js("window.pond && pond.pointer(0,0,'leave')")
            }
        }
    }

    /// 指针下是否就是桌面：直接问系统「这里点下去会点到哪个窗口」。
    /// 我们自己的池塘窗口不接收鼠标，所以会被跳过；
    /// 命中的是 Finder 桌面（负层级）或什么都没命中，就算点在桌面上。
    func desktopExposed(at loc: NSPoint, now: CFTimeInterval, fresh: Bool) -> Bool {
        let hit = NSWindow.windowNumber(at: loc, belowWindowWithWindowNumber: 0)
        if hit <= 0 { return true }
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]],
              let info = list.first else { return true }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        if layer < 0 { return true }                       // 桌面图标层、壁纸
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1
        if pid == Int(ProcessInfo.processInfo.processIdentifier) { return true }
        let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        // Finder 的桌面窗口在少数系统上层级为 0，但它铺满整块屏幕
        if owner == "Finder", let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }),
           abs(bounds.width - screen.frame.width) < 2, abs(bounds.height - screen.frame.height) < 2 { return true }
        return false
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "fish", accessibilityDescription: "半亩塘") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "鲤"
            }
            button.toolTip = "半亩塘"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(isLagoon ? "拍一下水面" : "撒一把鱼食", #selector(feedNow)))
        menu.addItem(.separator())
        menu.addItem(submenu("场景", opts([("锦鲤池（俯视）", "pond"), ("兰寿缸（正视）", "aquarium"), ("浅湾（俯瞰泻湖）", "lagoon")], config.scene), #selector(pickScene)))
        menu.addItem(.separator())
        if isLagoon {
            // 浅湾：桌面上没法拖卡片，改成从菜单放生
            var kinds: [(String, Any, Bool)] = []
            for (label, key) in [("蝠鲼", "manta"), ("斑点鹰鳐", "eagle"), ("蓝点魟", "stingray"), ("绿海龟", "turtle"),
                                 ("海月水母", "moonjelly"), ("海刺水母", "nettle"), ("一群银色小鱼", "school"),
                                 ("彩色鱼", "reef"), ("小丑鱼", "clown"), ("黑鳍礁鲨", "shark")] {
                kinds.append((label, key, false))
            }
            menu.addItem(submenu("放生", kinds, #selector(spawnCreature)))
            menu.addItem(item("恢复默认的生物数量", #selector(resetLagoon)))
            menu.addItem(.separator())
            menu.addItem(toggle("显示标题", config.showTitle, #selector(toggleTitle)))
        } else {
        if !isTank {
            menu.addItem(item("池塘名字…", #selector(renamePond)))
            let cityTitle = config.city.map { "天气城市：\($0.name)…" } ?? "设置天气城市…"
            menu.addItem(item(cityTitle, #selector(setCity)))
        }
        var counts: [(String, Any, Bool)] = []
        let choices = isTank ? [3, 5, 7, 9, 12, 15] : [20, 40, 60, 80, 100, 120]
        let current = isTank ? config.tankFishCount : config.fishCount
        for n in choices { counts.append(("\(n) 尾", n, current == n)) }
        menu.addItem(submenu("鱼的数量", counts, #selector(pickFishCount)))
        let timeOpts = isTank ? [("跟随真实时间（晚上开月光灯）", "auto"), ("开灯", "day"), ("月光灯", "night")]
                              : [("跟随真实时间", "auto"), ("白天", "day"), ("黄昏", "dusk"), ("夜晚", "night")]
        menu.addItem(submenu(isTank ? "灯光" : "时间", opts(timeOpts, config.timeMode), #selector(pickTime)))
        if !isTank {
            menu.addItem(submenu("天气", opts([("跟随真实天气", "auto"), ("晴", "clear"), ("阴", "cloudy"), ("雨", "rain"), ("雪", "snow"), ("雷雨", "storm")], config.weatherMode), #selector(pickWeather)))
            menu.addItem(submenu("季节", opts([("跟随日期", "auto"), ("春", "spring"), ("夏", "summer"), ("秋", "autumn"), ("冬", "winter")], config.seasonMode), #selector(pickSeason)))
        }
        menu.addItem(.separator())
        if !isTank { menu.addItem(toggle("显示池畔小记", config.showWidget, #selector(toggleWidget))) }
        menu.addItem(toggle(isTank ? "显示鱼缸名字" : "显示池塘名字", config.showTitle, #selector(toggleTitle)))
        }
        menu.addItem(toggle("鼠标互动（引鱼 / 喂食）", config.interactive, #selector(toggleInteractive)))
        let fpsOptions: [(String, Any, Bool)] = [("60 帧", 60, config.fps == 60), ("30 帧（更省电）", 30, config.fps == 30)]
        let perf = submenu("性能", fpsOptions, #selector(pickFps))
        perf.submenu?.addItem(.separator())
        perf.submenu?.addItem(toggle("省电画质", config.quality == "saver", #selector(toggleQuality)))
        menu.addItem(perf)
        menu.addItem(toggle("暂停动画", manualPause, #selector(togglePause)))
        if #available(macOS 13.0, *) {
            menu.addItem(toggle("开机自动启动", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        }
        menu.addItem(.separator())
        menu.addItem(item("关于半亩塘", #selector(about)))
        let quit = NSMenuItem(title: "退出半亩塘", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func opts(_ pairs: [(String, String)], _ current: String) -> [(String, Any, Bool)] {
        var out: [(String, Any, Bool)] = []
        for (label, value) in pairs { out.append((label, value, current == value)) }
        return out
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let it = item(title, sel)
        it.state = on ? .on : .off
        return it
    }

    func submenu(_ title: String, _ options: [(String, Any, Bool)], _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value, on) in options {
            let it = item(label, sel)
            it.representedObject = value
            it.state = on ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    func commit() {
        Store.save(config)
        pushConfig()
    }

    @objc func feedNow() {
        guard let p = ponds.first(where: { $0.screen == NSScreen.main }) ?? ponds.first else { return }
        let s = p.screen.frame.size
        p.js("window.pond && pond.feed(\(s.width * CGFloat.random(in: 0.35...0.65)), \(s.height * CGFloat.random(in: 0.35...0.65)))")
    }

    @objc func pickFishCount(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        if isTank { config.tankFishCount = v } else { config.fishCount = v }
        commit()
    }
    @objc func spawnCreature(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        for p in ponds { p.js("window.pond && pond.spawn && pond.spawn('\(k)')") }
    }
    @objc func resetLagoon() {
        for p in ponds { p.js("window.pond && pond.resetCounts && pond.resetCounts()") }
    }
    @objc func pickScene(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String, v != config.scene else { return }
        config.scene = v
        Store.save(config)
        buildPonds()          // 换一个页面重新加载，加载好后会自动淡入
    }
    @objc func pickTime(_ sender: NSMenuItem) { if let v = sender.representedObject as? String { config.timeMode = v; commit() } }
    @objc func pickWeather(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? String {
            config.weatherMode = v; commit()
            if v == "auto" && config.city == nil { setCity() }
        }
    }
    @objc func pickSeason(_ sender: NSMenuItem) { if let v = sender.representedObject as? String { config.seasonMode = v; commit() } }
    @objc func pickFps(_ sender: NSMenuItem) { if let v = sender.representedObject as? Int { config.fps = v; commit() } }
    @objc func toggleWidget() { config.showWidget.toggle(); commit() }
    @objc func toggleTitle() { config.showTitle.toggle(); commit() }
    @objc func toggleQuality() { config.quality = config.quality == "saver" ? "auto" : "saver"; commit() }
    @objc func toggleInteractive() {
        config.interactive.toggle(); commit()
        if !config.interactive { for p in ponds { p.js("window.pond && pond.pointer(0,0,'leave')") } }
    }
    @objc func togglePause() { manualPause.toggle(); applyPause() }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            let s = SMAppService.mainApp
            do {
                if s.status == .enabled { try s.unregister() } else { try s.register() }
            } catch {
                info("没能修改开机启动", "请先把「半亩塘.app」放进「应用程序」文件夹再试。\n\(error.localizedDescription)")
            }
        }
    }

    @objc func renamePond() {
        if let name = ask("给池塘起个名字", "最多 12 个字。", value: config.name) {
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            config.name = trimmed.isEmpty ? "半亩塘" : trimmed
            commit()
        }
    }

    @objc func setCity() {
        guard let q = ask("你所在的城市", "输入中文或拼音，例如：杭州。天气数据来自 Open-Meteo。", value: config.city?.name ?? "") else { return }
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let p = ponds.first,
              let data = try? JSONEncoder().encode(query), let lit = String(data: data, encoding: .utf8) else { return }
        p.js("window.pond && pond.searchCity(\(lit))")
    }

    @objc func about() {
        info("半亩塘", "半亩方塘一鉴开，天光云影共徘徊。\n\n移动指针，鱼会游过来；点击桌面空白处，撒一把鱼食。\n设置都在菜单栏的小鱼图标里。")
    }

    // MARK: 对话框

    func ask(_ title: String, _ message: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func info(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不在程序坞显示，只在菜单栏
app.run()
