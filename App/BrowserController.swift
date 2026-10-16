import AppKit
import Combine
import SwiftUI
import WebKit

private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

struct BrowserPage: Identifiable {
    let id: UUID
    let view: WKWebView
    let openerID: UUID?
    var title: String
}

@MainActor
final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let world = WKContentWorld.world(name: "HoriStudy")
    @Published var address = "https://i.chaoxing.com"
    @Published var title = "学习通"
    @Published var loading = false
    @Published var error = ""
    @Published var navigationNotice = ""
    @Published private(set) var pages: [BrowserPage]
    @Published private(set) var activePageID: UUID
    @Published private(set) var diagnostics: [BrowserDiagnostic] = []
    @Published var frames: [String: FrameSnapshot] = [:]
    @Published var navigationID = UUID()
    private var frameInfo: [String: WKFrameInfo] = [:]
    private var frameViews: [String: WKWebView] = [:]
    private var frameSeen: [String: Date] = [:]
    private var snapshots: [String: FrameSnapshot] = [:]
    private let writesDiagnostics: Bool
    private let diagnosticURL: URL?
    private let navigationPolicy: (URL, String, Bool) -> NavigationDecision
    var webView: WKWebView { pages.first(where: { $0.id == activePageID })!.view }

    override convenience init() { self.init(writesDiagnostics: true) }

    init(writesDiagnostics: Bool, configuration suppliedConfiguration: WKWebViewConfiguration? = nil,
         navigationPolicy: @escaping (URL, String, Bool) -> NavigationDecision = StudyNavigationPolicy.decide) {
        self.writesDiagnostics = writesDiagnostics
        self.navigationPolicy = navigationPolicy
        diagnosticURL = writesDiagnostics ? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/HoriStudy/navigation.jsonl") : nil
        let configuration = suppliedConfiguration ?? WKWebViewConfiguration()
        if suppliedConfiguration == nil { configuration.websiteDataStore = .default() }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let bridge = ScriptBridge()
        configuration.userContentController.add(bridge, contentWorld: Self.world, name: "horiStudy")
        if let path = Bundle.main.url(forResource: "chaoxing-adapter", withExtension: "js"),
           let script = try? String(contentsOf: path, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script,
                injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
        }
        let root = WKWebView(frame: .zero, configuration: configuration)
        let id = UUID()
        activePageID = id; pages = [BrowserPage(id: id, view: root, openerID: nil, title: "学习通")]
        super.init()
        bridge.owner = self
        configure(root)
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
    }
    static func trusted(_ host: String) -> Bool { StudyNavigationPolicy.trusted(host) }
    private func page(_ view: WKWebView) -> BrowserPage? { pages.first { $0.view === view } }
    private func isActive(_ view: WKWebView) -> Bool { page(view)?.id == activePageID }

    func selectPage(_ id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        activePageID = id; address = page.view.url?.absoluteString ?? "about:blank"
        title = page.view.title ?? page.title; loading = page.view.isLoading
        error = ""; navigationID = UUID(); refreshFrames()
    }
    func closePage(_ id: UUID) {
        guard pages.count > 1, let page = pages.first(where: { $0.id == id }), page.openerID != nil else { return }
        clearFrames(for: page.view)
        pages.removeAll { $0.id == id }
        page.view.stopLoading(); page.view.removeFromSuperview()
        if activePageID == id { selectPage(page.openerID.flatMap { opener in pages.first { $0.id == opener }?.id } ?? pages[0].id) }
    }
    func open(_ input: String = "https://i.chaoxing.com") {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            error = "请输入有效的 HTTPS 网页地址。"; return
        }
        error = ""; webView.load(URLRequest(url: url))
    }

    private func record(_ event: String, url: URL? = nil, error: NSError? = nil) {
        let entry = BrowserDiagnostic(event: event, url: url, error: error)
        diagnostics.append(entry)
        if diagnostics.count > 80 { diagnostics.removeFirst(diagnostics.count - 80) }
        guard writesDiagnostics, let diagnosticURL,
              var data = try? JSONEncoder().encode(entry) else { return }
        data.append(10)
        do {
            try FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: diagnosticURL.path)[.size]) as? NSNumber,
               size.intValue > 500_000 { try Data().write(to: diagnosticURL, options: .atomic) }
            if !FileManager.default.fileExists(atPath: diagnosticURL.path) {
                FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: diagnosticURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { /* A diagnostic write must never interrupt the page. */ }
    }
    var diagnosticText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development"
        let format = DateFormatter(); format.dateFormat = "HH:mm:ss"
        return (["HoriStudy \(version) (\(build))", "只含协议、主机和错误码；不含路径、查询参数、表单或 Cookie。"] + diagnostics.map {
            "\(format.string(from: $0.time)) \($0.event) \($0.scheme)://\($0.host) \($0.errorDomain) \($0.errorCode)"
        }).joined(separator: "\n")
    }

    func receive(_ message: WKScriptMessage) {
        guard let view = message.webView, page(view) != nil,
              message.name == "horiStudy", message.frameInfo.securityOrigin.protocol == "https",
              Self.trusted(message.frameInfo.securityOrigin.host),
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body), data.count < 2_000_000,
              let snapshot = try? JSONDecoder().decode(FrameSnapshot.self, from: data) else { return }
        frameInfo[snapshot.frameID] = message.frameInfo; frameViews[snapshot.frameID] = view
        frameSeen[snapshot.frameID] = Date(); snapshots[snapshot.frameID] = snapshot
        for (id, seen) in frameSeen where Date().timeIntervalSince(seen) > 7 { removeFrame(id) }
        refreshFrames()
    }
    private func removeFrame(_ id: String) {
        frameInfo.removeValue(forKey: id); frameViews.removeValue(forKey: id)
        frameSeen.removeValue(forKey: id); snapshots.removeValue(forKey: id)
    }
    private func clearFrames(for view: WKWebView) {
        for id in frameViews.keys.filter({ frameViews[$0] === view }) { removeFrame(id) }
        refreshFrames()
    }
    private func refreshFrames() { frames = snapshots.filter { frameViews[$0.key] === webView } }

    func command(_ action: String, frameID: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
        guard let frame = frameInfo[frameID], let view = frameViews[frameID], isActive(view),
              let seen = frameSeen[frameID], Date().timeIntervalSince(seen) < 8 else {
            throw StudyError.message("页面已变化或不再响应，请重新识别。")
        }
        var command = extra; command["action"] = action
        let result = try await view.callAsyncJavaScript("return await globalThis.HoriStudy.dispatch(command)",
            arguments: ["command": command], in: frame, contentWorld: Self.world)
        return result as? [String: Any] ?? [:]
    }
    func fill(_ question: StudyQuestion, with answer: AnswerDraft) async throws {
        guard frames[question.frameID]?.questions.contains(where: { $0.id == question.id && $0.signature == question.signature }) == true else {
            throw StudyError.message("题目已经变化，请重新识别。")
        }
        _ = try await command("fill", frameID: question.frameID,
            extra: ["id": question.id, "signature": question.signature, "selectedOptionIDs": answer.selectedOptionIDs,
                    "textAnswers": answer.textAnswers])
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        record("start", url: webView.url); clearFrames(for: webView)
        if isActive(webView) { loading = true; error = ""; navigationNotice = ""; navigationID = UUID() }
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        record("redirect", url: webView.url)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record("finished", url: webView.url)
        if let index = pages.firstIndex(where: { $0.view === webView }) { pages[index].title = webView.title ?? "网页" }
        if isActive(webView) { loading = false; error = ""; address = webView.url?.absoluteString ?? address; title = webView.title ?? "学习通" }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard page(webView) != nil else { return }
        let failure = error as NSError
        record("failed", url: BrowserFailure.failingURL(failure), error: failure)
        switch BrowserFailure.classify(failure) {
        case .cancelled:
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, self.isActive(webView) else { return }
                self.loading = webView.isLoading
            }
        case .unsupportedExternal(let scheme):
            if isActive(webView) { loading = webView.isLoading; navigationNotice = "网页登录触发了 \(scheme) 链接，当前网页登录页已保留。可查看登录诊断。" }
        case .failure(let message): if isActive(webView) { loading = false; self.error = message }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let sourceHost = navigationAction.sourceFrame.securityOrigin.host
        switch navigationPolicy(url, sourceHost, navigationAction.targetFrame?.isMainFrame ?? true) {
        case .allow: record("allow", url: url); decisionHandler(.allow)
        case .cancel: record("cancel", url: url); decisionHandler(.cancel)
        case .upgrade(let destination):
            record("upgrade-https", url: url); decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false {
                var request = navigationAction.request; request.url = destination
                DispatchQueue.main.async { [weak webView] in webView?.load(request) }
            } else if isActive(webView) {
                navigationNotice = "网页的旧版内嵌链接使用 HTTP，请尝试重新打开课程的 HTTPS 页面。"
            }
        case .externalApp(let scheme):
            record("external-link-cancelled", url: url); decisionHandler(.cancel)
            if isActive(webView), navigationAction.navigationType == .linkActivated {
                navigationNotice = "此链接用于打开其他应用（\(scheme)），请继续使用网页登录或手机扫码。"
            }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let opener = page(webView), pages.count < 6 else { return nil }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let policy = navigationAction.request.url.map { navigationPolicy($0, navigationAction.sourceFrame.securityOrigin.host, true) }
        guard scheme == nil || policy == .allow || { if case .upgrade = policy { return true }; return false }() else {
            record("popup-unsupported", url: navigationAction.request.url); return nil
        }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        let id = UUID()
        pages.append(BrowserPage(id: id, view: popup, openerID: opener.id, title: "登录 / 新页面"))
        selectPage(id); record("popup-created", url: navigationAction.request.url)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { if let id = page(webView)?.id { closePage(id) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = "网页提示"; alert.informativeText = String(message.prefix(3000))
        alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = "网页确认"; alert.informativeText = String(message.prefix(3000))
        alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

struct BrowserView: NSViewRepresentable {
    @ObservedObject var browser: BrowserController
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        let active = browser.webView
        guard container.subviews.first !== active else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        active.removeFromSuperview(); active.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(active)
        NSLayoutConstraint.activate([active.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            active.trailingAnchor.constraint(equalTo: container.trailingAnchor), active.topAnchor.constraint(equalTo: container.topAnchor),
            active.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
    }
}
