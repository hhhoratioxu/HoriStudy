import AppKit
import Foundation
import WebKit
import AVFoundation
import CoreVideo

@MainActor
final class AdapterHarness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var window: NSWindow!
    var continuation: CheckedContinuation<Void, Error>?
    var checks = 0
    var reportedFrames = Set<String>()
    var receivedFrameInfo: [String: WKFrameInfo] = [:]
    let world = WKContentWorld.world(name: "HoriStudy-tests")

    func start() async throws {
        try runCoreChecks()
        try await runNetworkChecks()
        try await runBrowserChecks()
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, contentWorld: world, name: "horiStudy")
        let script = try String(contentsOfFile: "Resources/chaoxing-adapter.js", encoding: .utf8)
        config.userContentController.addUserScript(WKUserScript(source: "const HORI_TEST_MODE = true;\n" + script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        let productionWorld = WKContentWorld.world(name: "HoriStudy-production-origin-check")
        config.userContentController.addUserScript(WKUserScript(source: script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: productionWorld))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "HoriStudy — local adapter checks"; window.contentView = webView
        window.orderBack(nil)
        try await load("""
        <!doctype html><html><head><title>本地测试</title></head><body>
        <div class="TiMu" data-question-type="single"><h3 data-question-stem>2 + 2 = ?</h3>
          <ul class="Zy_ulTop"><li><label><input type="radio" name="q1">A. 3</label></li><li><label><input type="radio" name="q1">B. 4</label></li></ul></div>
        <div class="mark_table" data-question-type="multiple"><h3 class="mark_name">选择偶数</h3>
          <ul class="mark_letter"><li><label><input type="checkbox">A. 2</label></li><li><label><input type="checkbox">B. 3</label></li><li><label><input type="checkbox">C. 4</label></li></ul></div>
        <div class="TiMu" data-question-type="fill"><h3 data-question-stem>请填写两个数</h3><textarea></textarea><textarea></textarea></div>
        <div class="TiMu" data-question-type="single"><h3 data-question-stem>图片题<img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/%3E"></h3><label><input type="radio">A. 选项</label></div>
        <button onclick="this.dataset.clicked='yes'">下一题</button>
        <button onclick="this.dataset.clicked='yes'">提交作业</button>
        <div id="secret" style="display:none">PRIVATE_COOKIE_SENTINEL</div>
        </body></html>
        """)
        let state = try await snapshot()
        let pageVisible = try await webView.callAsyncJavaScript("return typeof globalThis.HoriStudy", arguments: [:], in: nil, contentWorld: .page)
        ensure(pageVisible as? String == "undefined", "page scripts cannot access private automation world")
        let productionVisible = try await webView.callAsyncJavaScript("return typeof globalThis.HoriStudy", arguments: [:], in: nil, contentWorld: productionWorld)
        ensure(productionVisible as? String == "undefined", "production adapter ignores unrelated websites")
        ensure(state.questions.count == 4, "recognizes old and new question layouts")
        let q = state.questions[0]
        ensure(q.options.map(\.text) == ["3", "4"], "normalizes option labels without changing content")
        ensure(state.questions[1].kind == .multiple && state.questions[2].blankCount == 2, "recognizes multiple and fill questions")
        ensure(state.questions[3].unsupported, "flags image questions")
        ensure(state.submitCount == 1 && state.nextQuestion, "detects unique next and submit buttons")
        ensure(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("PRIVATE_COOKIE_SENTINEL"), "snapshot excludes unrelated page contents")
        let result = try await command(["action": "fill", "id": q.id, "signature": q.signature, "selectedOptionIDs": ["o1"], "textAnswers": []])
        ensure(result["ok"] as? Bool == true, "fills and reads back single choice")
        let submitClicked = try await js("document.querySelector('button:last-of-type').dataset.clicked || ''") as? String
        ensure(submitClicked == "", "filling never submits the form")
        do {
            _ = try await command(["action": "fill", "id": q.id, "signature": q.signature, "selectedOptionIDs": ["o0"], "textAnswers": []])
            ensure(false, "preserves existing student answer")
        } catch { ensure(true, "preserves existing student answer") }
        let multiple = state.questions[1]
        _ = try await command(["action": "fill", "id": multiple.id, "signature": multiple.signature, "selectedOptionIDs": ["o0", "o2"], "textAnswers": []])
        ensure(true, "fills exact multiple choice set")
        let fill = state.questions[2]
        _ = try await command(["action": "fill", "id": fill.id, "signature": fill.signature, "selectedOptionIDs": [], "textAnswers": ["10", "-2"]])
        ensure(try await js("[...document.querySelectorAll('textarea')].map(x => x.value).join('|')") as? String == "10|-2", "fills text using native input events")
        _ = try await js("document.querySelector('[data-question-stem]').textContent = 'changed'")
        do {
            _ = try await command(["action": "fill", "id": q.id, "signature": q.signature, "selectedOptionIDs": ["o1"], "textAnswers": []])
            ensure(false, "rejects stale question signatures")
        } catch { ensure(true, "rejects stale question signatures") }
        _ = try await js("let dialog=document.createElement('div'); dialog.setAttribute('role','dialog'); dialog.textContent='请完成安全验证码'; document.body.append(dialog)")
        ensure(!(try await snapshot()).blocked.isEmpty, "verification dialog pauses automation")
        do { _ = try await command(["action": "nextQuestion"]); ensure(false, "blocked page cannot navigate automatically") }
        catch { ensure(true, "blocked page cannot navigate automatically") }
        reportedFrames.removeAll(); receivedFrameInfo.removeAll()
        try await load("""
        <!doctype html><title>Nested questions</title>
        <div class="questionLi"><input type="hidden" name="type1" value="0"><h3 class="mark_name">新版作业</h3><div class="mark_table"><div class="mark_item"><div class="answerBg"><label class="answer_p"><input type="radio" name="new">A. 内容</label></div></div></div></div>
        <div class="TiMu"><input type="hidden" id="answertype2" value="2"><h3 class="Zy_TItle"><span class="clearfix">旧版填空</span></h3><ul class="Zy_ulTop"><li>第一个空<textarea></textarea></li></ul></div>
        <div class="TiMu"><input type="hidden" id="answertype3" value="11"><h3 class="Zy_TItle">组合题</h3><ul class="Zy_ulTop"><li>子项</li></ul></div>
        <div class="ans-job-icon ans-job-finished"></div><div class="ans-job-icon" style="width:10px;height:10px">未完成</div>
        <iframe srcdoc="&lt;html&gt;&lt;body&gt;&lt;div class='TiMu' data-question-type='single'&gt;&lt;h3 data-question-stem&gt;Frame question&lt;/h3&gt;&lt;label&gt;&lt;input type='radio'&gt;A. frame answer&lt;/label&gt;&lt;/div&gt;&lt;/body&gt;&lt;/html&gt;"></iframe>
        """)
        let nested = try await snapshot()
        ensure(nested.questions.count == 3, "nested layout preserves outer question stem")
        ensure(nested.questions[1].kind == .fill && nested.questions[1].options.isEmpty, "legacy text fields are not mistaken for choices")
        ensure(nested.questions[2].kind == .unknown, "unsupported platform type cannot fall back to single choice")
        ensure(nested.completion.isEmpty, "one finished task does not imply all tasks completed")
        try await Task.sleep(nanoseconds: 300_000_000)
        ensure(reportedFrames.count >= 2, "adapter runs independently in embedded frames")
        guard let childFrame = receivedFrameInfo.values.first(where: { !$0.isMainFrame }) else {
            throw StudyError.message("No embedded frame reported")
        }
        let childBody = try await webView.callAsyncJavaScript("return globalThis.HoriStudy.snapshot()", arguments: [:], in: childFrame, contentWorld: world)
        let child = try JSONDecoder().decode(FrameSnapshot.self, from: JSONSerialization.data(withJSONObject: childBody!))
        guard let childQuestion = child.questions.first else { throw StudyError.message("Embedded question missing") }
        let childResult = try await webView.callAsyncJavaScript("return await globalThis.HoriStudy.dispatch(command)",
            arguments: ["command": ["action": "fill", "id": childQuestion.id, "signature": childQuestion.signature,
                                    "selectedOptionIDs": ["o0"], "textAnswers": []] as [String: Any]],
            in: childFrame, contentWorld: world) as? [String: Any]
        ensure(childResult?["ok"] as? Bool == true, "native frame routing fills and verifies embedded question")
        let video = try await makeVideo()
        try await load("<html><title>Video test</title><video controls src='data:video/mp4;base64,\(video)'></video><button data-hori-next-chapter>下一节</button></html>")
        for _ in 0..<30 {
            if (try await snapshot()).videos.first?.duration ?? 0 > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try await command(["action": "playVideo"])
        try await Task.sleep(nanoseconds: 300_000_000)
        let playing = try await snapshot()
        ensure((playing.videos.first?.current ?? 0) > 0 && playing.videos.first?.ended == false, "video really advances without jumping to the end")
        ensure(try await js("document.querySelector('video').playbackRate") as? Double == 1, "video playback rate remains normal")
        do { _ = try await command(["action": "nextChapter"]); ensure(false, "cannot switch chapter before video ends") }
        catch { ensure(true, "cannot switch chapter before video ends") }
        _ = try await command(["action": "pauseVideo"])
        ensure((try await snapshot()).videos.first?.paused == true, "pause stops actual media playback")
        _ = try await command(["action": "playVideo"])
        for _ in 0..<40 {
            if (try await snapshot()).videos.first?.ended == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let ended = try await snapshot()
        ensure(ended.videos.first?.ended == true && ended.completion.isEmpty, "ended video alone never claims platform task completion")
        print("WebKit adapter checks: \(checks) passed")
        window.orderOut(nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], let id = body["frameID"] as? String {
            reportedFrames.insert(id); receivedFrameInfo[id] = message.frameInfo
        }
    }
    func makeVideo() async throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("horistudy-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else { throw StudyError.message("Video fixture buffer failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<60 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? StudyError.message("Video fixture failed") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? StudyError.message("Video fixture append failed")
            }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudyError.message("Video fixture encoding failed") }
        return try Data(contentsOf: url).base64EncodedString()
    }

    func ensure(_ value: Bool, _ label: String) {
        guard value else { print("FAIL: \(label)"); exit(1) }
        checks += 1; print("PASS: \(label)")
    }
    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
            continuation = value
            webView.loadHTMLString(html, baseURL: URL(string: "https://fixtures.horistudy.test"))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func js(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    func command(_ command: [String: Any]) async throws -> [String: Any] {
        try await webView.callAsyncJavaScript("return await globalThis.HoriStudy.dispatch(command)", arguments: ["command": command],
            in: nil, contentWorld: world) as? [String: Any] ?? [:]
    }
    func snapshot() async throws -> FrameSnapshot {
        let result = try await webView.callAsyncJavaScript("return globalThis.HoriStudy.snapshot()", arguments: [:], in: nil, contentWorld: world)
        return try JSONDecoder().decode(FrameSnapshot.self, from: JSONSerialization.data(withJSONObject: result!))
    }
}

@main
struct HarnessMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await AdapterHarness().start(); print("ALL LOCAL CHECKS PASSED"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
}
