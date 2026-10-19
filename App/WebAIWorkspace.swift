import AppKit
import Combine
import WebKit

@MainActor
final class WebAIWorkspace: ObservableObject {
    static let world = WKContentWorld.world(name: "HoriStudy-WebAI")
    @Published var selected = WebAIProvider.chatGPT
    @Published var browsers: [WebAIProvider: BrowserController] = [:]
    @Published var status = "选择服务并在真实网页中登录。订阅、模型和 Chat / Work 模式由网页管理。"
    var overrideScript: String?
    var browserFactory: ((WebAIProvider) -> BrowserController)?

    func open(_ provider: WebAIProvider) throws {
        if browsers[provider] == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: provider.dataStoreID)
            let script: String
            if let overrideScript { script = overrideScript }
            else if let url = Bundle.main.url(forResource: "ai-chat-adapter", withExtension: "js") { script = try String(contentsOf: url, encoding: .utf8) }
            else { throw StudyError.message("应用缺少 AI 网页适配文件，请重新安装完整预览版。") }
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
            browsers[provider] = browserFactory?(provider) ?? BrowserController(writesDiagnostics: false, configuration: configuration)
        }
        selected = provider
        if browsers[provider]!.webView.url == nil { browsers[provider]!.open(provider.homeURL.absoluteString) }
    }

    func answer(_ question: StudyQuestion, provider: WebAIProvider, reviewing: Bool,
                onDispatched: () -> Void = {}) async throws -> (AnswerDraft, [Citation]) {
        try Task.checkCancellation()
        try open(provider)
        guard let browser = browsers[provider], !browser.loading else { throw StudyError.message("\(provider.title) 页面仍在加载，请登录完成后再开始。") }
        let view = browser.webView
        let pageID = browser.activePageID
        let requestID = UUID().uuidString
        func command(_ action: String, prompt: String = "") async throws -> [String: Any] {
            try Task.checkCancellation()
            guard self.selected == provider, browser.activePageID == pageID, provider.accepts(view.url) else {
                throw StudyError.message("聊天页面已切换或尚未完成官方网页登录，流程已暂停。")
            }
            guard let result = try await view.callAsyncJavaScript("return await globalThis.HoriChat.dispatch(command)",
                arguments: ["command": ["action": action, "provider": provider.rawValue, "id": requestID, "prompt": prompt]],
                in: nil, contentWorld: Self.world) as? [String: Any] else { throw StudyError.message("无法读取聊天网页状态。") }
            return result
        }
        func requireOK(_ result: [String: Any]) throws {
            guard result["ok"] as? Bool == true else { throw StudyError.message(result["error"] as? String ?? "聊天网页操作未完成。") }
        }
        let fresh = try await command("newChat"); try requireOK(fresh)
        if fresh["fresh"] as? Bool != true {
            var ready = false
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 250_000_000)
                let state = try await command("inspect")
                // A login/clear-chat confirmation needs the user; do not keep waiting for a blank composer.
                if ["conversationConfirmation", "authentication", "loginForNewConversation"].contains(state["kind"] as? String ?? "") {
                    try requireOK(state)
                }
                if state["ok"] as? Bool == true, state["count"] as? Int == 0, state["draft"] as? Bool == false, state["busy"] as? Bool == false { ready = true; break }
            }
            guard ready else { throw StudyError.message("未能确认空白新对话，未发送题目。请在网页手动开启新对话。") }
        }
        let prompt = try WebAnswerFormat.prompt(question: question, requestID: requestID, reviewing: reviewing)
        try requireOK(await command("prepare", prompt: prompt))
        var dispatched = false
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 250_000_000)
            let result = try await command("send")
            if result["ok"] as? Bool == true { dispatched = true; break }
            if result["retryable"] as? Bool != true { try requireOK(result) }
        }
        guard dispatched else { throw StudyError.message("网页发送按钮不可用。题目草稿保留，请在网页核对。") }
        onDispatched()
        status = "\(provider.title) 已发送，等待网页完成本次回答；不会自动重发。"
        var previous = ""; var stable = 0
        for _ in 0..<240 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let result = try await command("reply"); try requireOK(result)
            if result["done"] as? Bool != true {
                if result["matching"] as? Int == 1 { status = result["busy"] as? Bool == true ? "本题 JSON 已找到，网页仍报告正在生成；不会重发。" : "本题完整 JSON 已找到，等待网站的回答完成标记；不会重发。" }
                else if (result["observed"] as? Int ?? 0) > 0 { status = "已识别到本次回答，等待与本题标识匹配的完整 JSON；不会重发。" }
                else { status = "题目已发送，尚未识别到本次回答。若网页已完成，可取消后手动复制导入；不会重发。" }
            }
            guard result["done"] as? Bool == true, let text = result["text"] as? String else { stable = 0; continue }
            stable = text == previous ? stable + 1 : 0; previous = text
            guard stable >= 2 else { continue }
            let draft = try WebAnswerFormat.decode(text, requestID: requestID)
            var sources: [Citation] = []
            for link in result["links"] as? [[String: String]] ?? [] {
                guard let url = link["url"], !sources.contains(where: { $0.url == url }) else { continue }
                let source = Citation(id: "web\(sources.count + 1)", title: link["title"] ?? url, url: url)
                if source.safeURL != nil { sources.append(source) }
            }
            status = "已读取本次完整回答。网页来源尚需核对。"
            return (draft, sources)
        }
        throw StudyError.message("等待网页回答超时，已暂停且不会重发。请查看是否需要登录、验证、额度处理，或手动结束 Work 任务。")
    }
}
