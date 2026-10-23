// 半亩塘 · 屏保
// 一个 ScreenSaverView，里面用 WKWebView 播放 web/aquarium.html 或 web/index.html。
// 屏保没有鼠标互动，所以每隔一会儿自动撒一把鱼食，让鱼动起来。

import Cocoa
import ScreenSaver
import WebKit

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
        guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "web") else { return }
        let wv = WKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        addSubview(wv)
        wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        web = wv
    }

    // 页面加载完：藏起名字、提示和小组件，屏保只留画面
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let js = """
        window.pond && pond.setConfig({showTitle:false, showWidget:false});
        ['hint','tag','plaque','journal'].forEach(function(id){var e=document.getElementById(id); if(e) e.style.display='none';});
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    override func startAnimation() {
        super.startAnimation()
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
