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

@MainActor
final class BrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let world = WKContentWorld.world(name: "HoriStudy")
    @Published var address = "https://i.chaoxing.com"
    @Published var title = "学习通"
    @Published var loading = false
    @Published var error = ""
    @Published var navigationNotice = ""
    @Published var frames: [String: FrameSnapshot] = [:]
    @Published var navigationID = UUID()
    private var frameInfo: [String: WKFrameInfo] = [:]
    private var frameSeen: [String: Date] = [:]
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let bridge = ScriptBridge()
        configuration.userContentController.add(bridge, contentWorld: Self.world, name: "horiStudy")
        if let path = Bundle.main.url(forResource: "chaoxing-adapter", withExtension: "js"),
           let script = try? String(contentsOf: path, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(source: script,
                injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        bridge.owner = self
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    static func trusted(_ host: String) -> Bool {
        StudyNavigationPolicy.trusted(host)
    }

    func open(_ input: String = "https://i.chaoxing.com") {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            error = "请输入有效的 HTTPS 网页地址。"; return
        }
        error = ""; webView.load(URLRequest(url: url))
    }

    func receive(_ message: WKScriptMessage) {
        guard message.name == "horiStudy", message.frameInfo.securityOrigin.protocol == "https",
              Self.trusted(message.frameInfo.securityOrigin.host),
              JSONSerialization.isValidJSONObject(message.body),
              let data = try? JSONSerialization.data(withJSONObject: message.body), data.count < 2_000_000,
              let snapshot = try? JSONDecoder().decode(FrameSnapshot.self, from: data) else { return }
        frameInfo[snapshot.frameID] = message.frameInfo
        frameSeen[snapshot.frameID] = Date()
        frames[snapshot.frameID] = snapshot
        for (id, seen) in frameSeen where Date().timeIntervalSince(seen) > 7 {
            frames.removeValue(forKey: id); frameInfo.removeValue(forKey: id); frameSeen.removeValue(forKey: id)
        }
    }

    func command(_ action: String, frameID: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
        guard let frame = frameInfo[frameID], let seen = frameSeen[frameID], Date().timeIntervalSince(seen) < 8 else {
            throw StudyError.message("页面已变化或不再响应，请重新识别。")
        }
        var command = extra; command["action"] = action
        let result = try await webView.callAsyncJavaScript("return await globalThis.HoriStudy.dispatch(command)",
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

    func navigation(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; error = ""; navigationNotice = ""; navigationID = UUID()
        frames.removeAll(); frameInfo.removeAll(); frameSeen.removeAll()
    }
    // WKNavigationDelegate uses this selector (the method above is intentionally named below).
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.navigation(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; address = webView.url?.absoluteString ?? address; title = webView.title ?? "学习通"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { self.error = "网页加载失败：\(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let sourceHost = navigationAction.sourceFrame.securityOrigin.host
        switch StudyNavigationPolicy.decide(url: url, sourceHost: sourceHost,
                                            mainFrame: navigationAction.targetFrame?.isMainFrame ?? true) {
        case .allow: decisionHandler(.allow)
        case .cancel: decisionHandler(.cancel)
        case .upgrade(let destination):
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false {
                var upgradedRequest = navigationAction.request; upgradedRequest.url = destination
                webView.load(upgradedRequest)
            }
            else { navigationNotice = "网页的旧版内嵌链接使用 HTTP，请尝试重新打开课程的 HTTPS 页面。" }
        case .externalApp(let scheme):
            decisionHandler(.cancel)
            // Websites probe mobile deep links during normal login. A failed probe is not a page error.
            if navigationAction.navigationType == .linkActivated {
                navigationNotice = "此链接用于打开其他应用（\(scheme)），请继续使用网页登录或手机扫码。"
            }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }
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
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
