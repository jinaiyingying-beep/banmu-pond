// 半亩塘 · 屏保
// 一个 ScreenSaverView，里面用 WKWebView 播放 web/aquarium.html 或 web/index.html。
// 屏保没有鼠标互动，所以每隔一会儿自动撒一把鱼食，让鱼动起来。

import Cocoa
import ScreenSaver
import WebKit
import os

private let saverLog = OSLog(subsystem: "local.banmu.saver", category: "saver")
private func slog(_ msg: String) { os_log("BanmuSaver: %{public}@", log: saverLog, type: .default, msg) }

@objc(BanmuSaverView)
final class BanmuSaverView: ScreenSaverView, WKNavigationDelegate {
    private var web: WKWebView?
    private var feedTimer: Timer?
    private var sheet: NSWindow?
    private var popup: NSPopUpButton?
    private let prefs: UserDefaults? = ScreenSaverDefaults(forModuleWithName: "local.banmu.saver")

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        slog("init preview=\(isPreview) frame=\(NSStringFromRect(frame))")
        animationTimeInterval = 1.0
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.34, alpha: 1).cgColor
        loadScene()
        // macOS 14 起的已知问题：屏保结束后进程不退出、下次会叠在一起。收到结束通知就退出。
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(willStop),
            name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
    }

    private var scene: String { prefs?.string(forKey: "scene") ?? "aquarium" }

    private func loadScene() {
        web?.removeFromSuperview()
        let bundle = Bundle(for: BanmuSaverView.self)
        let name = scene == "pond" ? "index" : "aquarium"
        guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "web"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            slog("找不到页面 \(name).html，bundle=\(bundle.bundlePath)")
            return
        }
        let wv = WKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        addSubview(wv)
        // 屏保在系统沙盒里运行，网页进程不一定能读文件；直接把整页内容交给它，不需要读文件
        wv.loadHTMLString(html, baseURL: nil)
        web = wv
        slog("loadHTMLString \(name) \(html.count) chars, bounds=\(NSStringFromRect(bounds))")
        // 3 秒后自查一次画面有没有在跑
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak wv] in
            wv?.evaluateJavaScript("document.readyState + ' ' + innerWidth + 'x' + innerHeight + ' fish=' + (typeof fishes !== 'undefined' ? fishes.length : 'none')") { result, error in
                slog("self-check: \(String(describing: result)) err=\(String(describing: error))")
                _ = self
            }
        }
    }

    // 网页还没出来之前（或者出不来时）能看到的底色和字样，用来判断屏保本身有没有跑起来
    override func draw(_ rect: NSRect) {
        NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.34, alpha: 1).setFill()
        bounds.fill()
        let text = "半亩塘" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(14, bounds.height * 0.04), weight: .light),
            .foregroundColor: NSColor(white: 1, alpha: 0.6),
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        slog("didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        slog("didFailProvisional: \(error.localizedDescription)")
    }

    // 页面加载完：藏起名字、提示和小组件，屏保只留画面
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        slog("didFinish")
        let js = """
        window.pond && pond.setConfig({showTitle:false, showWidget:false});
        ['hint','tag','plaque','journal'].forEach(function(id){var e=document.getElementById(id); if(e) e.style.display='none';});
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        slog("web content process terminated, reloading")
        loadScene()
    }

    override func startAnimation() {
        super.startAnimation()
        slog("startAnimation")
        feedTimer?.invalidate()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.web?.evaluateJavaScript(
                "window.pond && pond.feed(innerWidth*(0.25+Math.random()*0.5), innerHeight*0.4)",
                completionHandler: nil)
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        feedTimer?.invalidate()
        feedTimer = nil
    }

    override func animateOneFrame() {
        // 动画由网页自己跑，这里不需要做事
    }

    @objc private func willStop() {
        slog("willstop")
        if !isPreview { exit(0) }
    }

    // MARK: 「屏幕保护程序选项…」：选场景

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
                         styleMask: [.titled], backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: "屏保里放哪个场景：")
        label.frame = NSRect(x: 20, y: 88, width: 280, height: 20)
        let pop = NSPopUpButton(frame: NSRect(x: 18, y: 54, width: 284, height: 28), pullsDown: false)
        pop.addItems(withTitles: ["兰寿缸（正视）", "锦鲤池（俯视）"])
        pop.selectItem(at: scene == "pond" ? 1 : 0)
        let ok = NSButton(title: "好", target: self, action: #selector(closeSheet))
        ok.frame = NSRect(x: 220, y: 12, width: 82, height: 32)
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        w.contentView?.addSubview(label)
        w.contentView?.addSubview(pop)
        w.contentView?.addSubview(ok)
        sheet = w
        popup = pop
        return w
    }

    @objc private func closeSheet() {
        if let p = popup {
            prefs?.set(p.indexOfSelectedItem == 1 ? "pond" : "aquarium", forKey: "scene")
            prefs?.synchronize()
        }
        if let s = sheet {
            if let parent = s.sheetParent { parent.endSheet(s) } else { s.orderOut(nil) }
        }
        loadScene()
    }
}
