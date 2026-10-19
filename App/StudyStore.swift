import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct QuestionResult: Identifiable {
    var id: String { question.id }
    let question: StudyQuestion
    var status = "待查证"
    var answer: CheckedAnswer?
    var filled = false
    var error = ""
}

@MainActor
final class StudyStore: ObservableObject {
    let browser = BrowserController()
    let webAI = WebAIWorkspace()
    @Published var showWebAI = false
    @Published var answerConnectionMode: AnswerConnectionMode {
        didSet { UserDefaults.standard.set(answerConnectionMode.rawValue, forKey: "answerConnectionMode") }
    }
    @Published var webPreferences: WebAIPreferences {
        didSet { if let data = try? JSONEncoder().encode(webPreferences) { UserDefaults.standard.set(data, forKey: "webPreferences.v1") } }
    }
    @Published var webMessageCount = 0
    @Published var results: [QuestionResult] = []
    @Published var selectedQuestion: String?
    @Published var status = "打开课程中的作业、试卷或视频页面，即可开始。"
    @Published var running = false
    @Published var continuousVideo = false
    @Published var autoFill = true
    @Published var autoNextQuestion = true
    @Published var autoNextChapter = false
    @Published var showSettings = false
    @Published var error = ""
    @Published var bankCount = 0
    @Published var requestCount = 0
    @Published var aiPreferences: AIPreferences {
        didSet { if let data = try? JSONEncoder().encode(aiPreferences) { UserDefaults.standard.set(data, forKey: "aiPreferences.v1") } }
    }
    @Published var aiTestRunning = false
    @Published var aiTestMessage = ""
    @Published var maxQuestions: Int { didSet { UserDefaults.standard.set(maxQuestions, forKey: "maxQuestions") } }
    private var bank = AnswerBank()
    private var worker: Task<Void, Never>?
    private var aiTestWorker: Task<Void, Never>?
    private var manualPrompt: (question: StudyQuestion, requestID: String)?
    private var videoTimer: AnyCancellable?
    private var videoBusy = false
    private var hasPlayedVideo = false
    private var playbackNavigation = UUID()
    private var videoEndedAt: Date?
    private var lastVideoAction = Date.distantPast
    private var runID = UUID()
    private let supportDirectory: URL

    init() {
        let defaults = UserDefaults.standard
        answerConnectionMode = AnswerConnectionMode(rawValue: defaults.string(forKey: "answerConnectionMode") ?? "") ?? .web
        webPreferences = defaults.data(forKey: "webPreferences.v1").flatMap { try? JSONDecoder().decode(WebAIPreferences.self, from: $0) } ?? WebAIPreferences()
        if let data = defaults.data(forKey: "aiPreferences.v1"), let saved = try? JSONDecoder().decode(AIPreferences.self, from: data) {
            aiPreferences = saved
        } else {
            var initial = AIPreferences()
            initial.answer.model = defaults.string(forKey: "answerModel") ?? AIProvider.openAI.defaultModel
            initial.review.model = defaults.string(forKey: "reviewModel") ?? AIProvider.openAI.defaultModel
            initial.researchModel = initial.answer.model
            aiPreferences = initial
        }
        maxQuestions = defaults.object(forKey: "maxQuestions") as? Int ?? 10
        supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoriStudy", isDirectory: true)
        if let data = try? Data(contentsOf: supportDirectory.appendingPathComponent("answer-bank.json")),
           let file = try? JSONDecoder().decode(BankFile.self, from: data), file.version == 1 {
            bank.entries = file.entries; bankCount = bank.entries.count
        }
        // Do not prompt for Keychain access until the user opens settings or starts a request.
        videoTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.videoTick() }
        }
    }

    var selected: QuestionResult? { results.first { $0.id == selectedQuestion } }
    var filledCount: Int { results.filter(\.filled).count }
    var eligibleCount: Int { results.filter { $0.answer?.eligible == true && !$0.filled }.count }

    func openWebAI(_ provider: WebAIProvider) {
        do { try webAI.open(provider); showWebAI = true }
        catch { self.error = error.localizedDescription }
    }

    private func solveWithWeb(_ question: StudyQuestion) async throws -> CheckedAnswer {
        let preferences = webPreferences
        showWebAI = true
        status = "正在使用 \(preferences.answer.title) 网页作答。"
        let (first, firstSources) = try await webAI.answer(question, provider: preferences.answer, reviewing: false) { self.webMessageCount += 1 }
        update(question.id) {
            $0.answer = CheckedAnswer(draft: first, sources: firstSources, verification: "网页第一轮 · 复核未完成", eligible: false,
                reason: "第一轮回答已读取，尚未完成第二轮复核。不能作为通过两轮核验的答案。",
                attribution: "网页登录作答：\(preferences.answer.title)")
        }
        try Task.checkCancellation()
        status = "正在使用 \(preferences.review.title) 的新会话复核。"
        let second: AnswerDraft
        let secondSources: [Citation]
        do {
            (second, secondSources) = try await webAI.answer(question, provider: preferences.review, reviewing: true) { self.webMessageCount += 1 }
        } catch is CancellationError { throw CancellationError() }
        catch { throw StudyError.message("第一轮回答已读取；\(preferences.review.title) 网页复核未完成：\(error.localizedDescription)") }
        var sources = firstSources
        for source in secondSources where !sources.contains(where: { $0.url == source.url }) {
            sources.append(Citation(id: "web\(sources.count + 1)", title: source.title, url: source.url))
        }
        return WebAnswerFormat.check(first, second, question: question, preferences: preferences, sources: sources)
    }

    func copySelectedWebPrompt() {
        guard let row = selected, !row.question.unsupported, row.question.kind != .unknown else { error = "请先识别并选择一道可读取的题目。"; return }
        let id = UUID().uuidString
        do {
            let prompt = try WebAnswerFormat.prompt(question: row.question, requestID: id, reviewing: false)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string)
            manualPrompt = (row.question, id); status = "已复制本题提示，可在网页登录后手动发送。"
        } catch { self.error = error.localizedDescription }
    }

    func importWebAnswerFromClipboard() {
        guard !running, let pending = manualPrompt, let row = selected,
              pending.question == row.question, let text = NSPasteboard.general.string(forType: .string) else {
            error = "请先复制当前题目的提示；网页回答需带有同一次请求标识。"; return
        }
        do {
            let draft = try WebAnswerFormat.decode(text, requestID: pending.requestID)
            if let reason = AnswerGate.validate(draft, for: row.question) { throw StudyError.message(reason) }
            let answer = CheckedAnswer(draft: draft, sources: [], verification: "手动导入网页草稿 · 尚未复核", eligible: false,
                reason: "这是你复制回来的单轮网页回答，没有独立复核或来源核验。请核对后再填写。")
            update(row.id) { $0.answer = answer; $0.status = "需人工核对" }
            manualPrompt = nil; status = "已读取本次网页回答，请核对题目与答案。"
        } catch { self.error = error.localizedDescription }
    }

    func chooseAnswerProvider(_ provider: AIProvider) {
        let previous = aiPreferences.answer.provider
        guard provider != previous else { return }
        var next = aiPreferences
        next.answer = AIModelChoice(provider: provider)
        if next.review.provider == previous { next.review = AIModelChoice(provider: provider) }
        // Selecting another service should be usable with that service's key alone.
        if provider != .openAI { next.useWebResearch = false }
        aiPreferences = next
    }

    private func apiKeys(for preferences: AIPreferences) throws -> [AIProvider: String] {
        try preferences.validate()
        var keys: [AIProvider: String] = [:]
        for provider in preferences.requiredProviders {
            let key = try KeychainStore.read(scope: preferences.scope(for: provider))
            guard !key.isEmpty else { throw StudyError.message("请在设置中保存 \(provider.title) 的 API 密钥。") }
            keys[provider] = key
        }
        return keys
    }

    func testAIConnection() {
        guard !running && !aiTestRunning else { return }
        let preferences = aiPreferences
        let webMode = answerConnectionMode == .web
        let keys: [AIProvider: String]
        do { keys = webMode ? [:] : try apiKeys(for: preferences) }
        catch { aiTestMessage = error.localizedDescription; return }
        aiTestRunning = true; aiTestMessage = "正在用自编示例题检查当前配置…"
        aiTestWorker = Task {
            defer { aiTestRunning = false; aiTestWorker = nil }
            let question = StudyQuestion(id: "connection-test", frameID: "local", signature: "local",
                stem: "在 HTTP 标准状态码中，404 的标准语义是哪一项？", kind: .single,
                options: [QuestionOption(id: "o0", label: "A", text: "服务器内部错误"),
                          QuestionOption(id: "o1", label: "B", text: "未找到目标资源")],
                blankCount: 0, unsupported: false, context: "")
            do {
                let answer: CheckedAnswer
                if webMode {
                    aiTestMessage = "正在检查网页登录作答与新会话复核…"
                    answer = try await solveWithWeb(question)
                } else {
                    answer = try await AnswerPipeline(preferences: preferences, keys: keys).run(question) { stage in
                    switch stage {
                    case .research: self.aiTestMessage = "正在检查 OpenAI 联网检索…"
                    case .answer: self.aiTestMessage = "正在检查 \(preferences.answer.provider.title) 作答…"
                    case .review: self.aiTestMessage = "正在检查 \(preferences.review.provider.title) 复核…"
                    }
                }
                }
                let sampleCorrect = answer.draft.selectedOptionIDs == ["o1"]
                aiTestMessage = "已返回完整结果。\(sampleCorrect ? "本次示例答案符合预期。" : "本次示例答案不符合预期，请核对模型。")\(answer.verification)。单次示例不代表其他题目的准确率。"
                status = "AI 连接测试结束，请查看示例结果。"
            } catch is CancellationError {
                aiTestMessage = "连接测试已取消。"; status = "AI 连接测试已取消；已发出的网页请求可在网站停止。"
                if webMode { webAI.status = "本机测试已取消，不会继续发送。" }
            } catch {
                aiTestMessage = error.localizedDescription; status = "AI 连接测试已暂停，请处理提示后再试。"
                if webMode { webAI.status = "测试已暂停，不会自动重发。" }
            }
        }
    }

    func cancelAITest() { aiTestWorker?.cancel() }

    func scan() {
        let questions = browser.frames.values.sorted { $0.frameID < $1.frameID }.flatMap(\.questions)
        let old = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        results = questions.map { question in
            if let prior = old[question.id], prior.question.signature == question.signature { return prior }
            return QuestionResult(question: question)
        }
        if selectedQuestion == nil || !results.contains(where: { $0.id == selectedQuestion }) { selectedQuestion = results.first?.id }
        if let blocked = browser.frames.values.first(where: { !$0.blocked.isEmpty })?.blocked { status = blocked }
        else { status = results.isEmpty ? "尚未识别到题目，请打开具体的作业或试卷页面。" : "识别到 \(results.count) 道题。点击「开始核验」查询答案。" }
    }

    func update(_ id: String, _ body: (inout QuestionResult) -> Void) {
        if let index = results.firstIndex(where: { $0.id == id }) { body(&results[index]) }
    }

    func start() {
        guard !running && !aiTestRunning else { return }
        continuousVideo = false
        scan(); error = ""
        guard !results.isEmpty else { return }
        guard browser.frames.values.allSatisfy({ $0.blocked.isEmpty }) else { return }
        running = true; requestCount = 0; webMessageCount = 0; runID = UUID()
        let currentRun = runID
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.runID == currentRun { self.running = false; self.worker = nil } }
            do { try await self.process(run: currentRun) }
            catch is CancellationError { self.status = "已暂停；尚未提交的答案保留在网页中。" }
            catch {
                self.error = error.localizedDescription; self.status = "流程已暂停，请核对提示。"
                if let id = self.selectedQuestion {
                    self.update(id) { $0.status = "流程已暂停"; $0.error = error.localizedDescription }
                }
            }
        }
    }

    private func process(run: UUID) async throws {
        let limit = min(100, max(1, maxQuestions))
        var processed = 0
        while processed < limit {
            try Task.checkCancellation()
            guard run == runID else { return }
            if let block = browser.frames.values.first(where: { !$0.blocked.isEmpty })?.blocked { throw StudyError.message(block) }
            guard let row = results.first(where: { $0.status == "待查证" }) else {
                if autoNextQuestion && !results.isEmpty && results.allSatisfy(\.filled),
                   let frame = browser.frames.values.first(where: { $0.nextQuestion }) {
                    let oldIDs = Set(results.map(\.id)); let oldNav = browser.navigationID
                    status = "当前页已填完，正在进入下一题。"
                    _ = try await browser.command("nextQuestion", frameID: frame.frameID)
                    for _ in 0..<20 {
                        try await Task.sleep(nanoseconds: 500_000_000)
                        try Task.checkCancellation()
                        let questions = browser.frames.values.flatMap(\.questions)
                        if !questions.isEmpty && (browser.navigationID != oldNav || Set(questions.map(\.id)) != oldIDs ||
                            questions.contains(where: { q in !results.contains(where: { $0.question.signature == q.signature }) })) { break }
                    }
                    scan()
                    if Set(results.map(\.id)) == oldIDs && browser.navigationID == oldNav {
                        status = "页面没有切换到新题目，已暂停自动翻页。"; break
                    }
                    if results.isEmpty { status = "下一页尚未出现可识别题目，请手动打开后再继续。"; break }
                    continue
                }
                status = "本页处理结束：已填写 \(filledCount) 道。核对后可使用「提交此页」。"; return
            }
            processed += 1; selectedQuestion = row.id
            let q = row.question
            if q.unsupported || q.kind == .unknown {
                update(q.id) { $0.status = "需人工核对"; $0.error = "题型、图片或公式无法可靠读取，未发送给 AI。" }
                continue
            }
            let checked: CheckedAnswer
            switch bank.match(q) {
            case .found(let value): checked = value
            case .conflict(let reason):
                update(q.id) { $0.status = "答案冲突"; $0.error = reason }; continue
            case .none:
                if answerConnectionMode == .web {
                    update(q.id) { $0.status = "网页作答与复核中" }
                    checked = try await solveWithWeb(q)
                    break
                }
                let preferences = aiPreferences
                let keys: [AIProvider: String]
                do { keys = try apiKeys(for: preferences) }
                catch { showSettings = true; throw error }
                checked = try await AnswerPipeline(preferences: preferences, keys: keys).run(q) { stage in
                    self.requestCount += 1
                    switch stage {
                    case .research:
                        self.update(q.id) { $0.status = "联网查证中" }
                        self.status = "第 \(processed) 道：正在检索实际来源。"
                    case .answer:
                        self.update(q.id) { $0.status = "生成答案中" }
                        self.status = "正在使用 \(preferences.answer.provider.title) 作答。"
                    case .review:
                        self.update(q.id) { $0.status = "第二轮核对中" }
                        self.status = "正在使用 \(preferences.review.provider.title) 独立复核。"
                    }
                }
            }
            try Task.checkCancellation()
            guard run == runID else { return }
            update(q.id) { $0.answer = checked; $0.status = checked.eligible ? "可填写" : "需人工核对" }
            if checked.eligible && autoFill {
                do {
                    try await browser.fill(q, with: checked.draft)
                    update(q.id) { $0.filled = true; $0.status = "已填写 · 未提交" }
                } catch {
                    update(q.id) { $0.status = "填写待核对"; $0.error = error.localizedDescription }
                    throw error
                }
            }
        }
        status = "已达到本次 \(limit) 道题上限。可核对结果后继续。"
    }

    func fillEligible() {
        guard !running else { return }
        running = true
        worker = Task {
            defer { running = false; worker = nil }
            do {
                for row in results where row.answer?.eligible == true && !row.filled {
                    try Task.checkCancellation()
                    try await browser.fill(row.question, with: row.answer!.draft)
                    update(row.id) { $0.filled = true; $0.status = "已填写 · 未提交" }
                }
                status = "已填入通过核验的答案，请在网页中复核后提交。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func pause() {
        worker?.cancel(); aiTestWorker?.cancel(); continuousVideo = false
        for frame in browser.frames.values where !frame.videos.isEmpty {
            Task { _ = try? await browser.command("pauseVideo", frameID: frame.frameID) }
        }
        status = answerConnectionMode == .web ? "已暂停后续操作。已发出的网页请求可能仍在生成，可在网站点击停止。" : "已暂停。"
    }

    func fillSelectedAfterReview() {
        guard !running, !aiTestRunning, let row = selected, let answer = row.answer,
              !row.filled, AnswerGate.validate(answer.draft, for: row.question) == nil else { return }
        let alert = NSAlert()
        alert.messageText = "填入你已核对的本题答案？"
        alert.informativeText = "\(answer.reason)\n\n请先查看题目、解析及来源。此操作只填写本题，最终提交仍需你检查。"
        alert.addButton(withTitle: "我已核对，填入本题"); alert.addButton(withTitle: "返回检查")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        running = true
        worker = Task {
            defer { running = false; worker = nil }
            do {
                try Task.checkCancellation()
                try await browser.fill(row.question, with: answer.draft)
                update(row.id) { $0.filled = true; $0.status = "手动核对 · 未提交" }
                status = "已填入你核对的本题答案，请检查网页中的结果。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func retrySelected() {
        guard let id = selectedQuestion, !running else { return }
        update(id) { $0.status = "待查证"; $0.error = ""; $0.answer = nil; $0.filled = false }
    }

    func startVideo() {
        guard !running else { return }
        continuousVideo = true; hasPlayedVideo = false; videoEndedAt = nil
        playbackNavigation = browser.navigationID; lastVideoAction = .distantPast
        status = "连续播放已开启，视频将按网页允许的方式实际播放。"
        Task { await videoTick() }
    }

    private func videoTick() async {
        guard continuousVideo, !videoBusy else { return }
        videoBusy = true; defer { videoBusy = false }
        if browser.loading { return }
        if playbackNavigation != browser.navigationID {
            playbackNavigation = browser.navigationID; hasPlayedVideo = false; videoEndedAt = nil
        }
        if let block = browser.frames.values.first(where: { !$0.blocked.isEmpty })?.blocked {
            continuousVideo = false; status = block; return
        }
        let videoFrames = browser.frames.values.filter { !$0.videos.isEmpty }
        let videos = videoFrames.flatMap(\.videos)
        if videos.contains(where: { !$0.paused && !$0.ended }) {
            hasPlayedVideo = true; videoEndedAt = nil; status = "视频正在实际播放。"; return
        }
        do {
            if let frame = videoFrames.first(where: { $0.videos.contains(where: { !$0.ended }) }) {
                if Date().timeIntervalSince(lastVideoAction) < 8 { return }
                lastVideoAction = Date()
                _ = try await browser.command("playVideo", frameID: frame.frameID)
                hasPlayedVideo = true; return
            }
            if !videos.isEmpty && videos.allSatisfy(\.ended) && hasPlayedVideo {
                if videoEndedAt == nil { videoEndedAt = Date(); status = "视频播放结束，等待网页回写任务状态。"; return }
                guard Date().timeIntervalSince(videoEndedAt!) >= 8 else { return }
                if autoNextChapter {
                    // Completion must come from a DOM completion indicator, not the playback clock alone.
                    guard browser.frames.values.contains(where: { !$0.completion.isEmpty }) else {
                        continuousVideo = false; status = "视频已结束，但页面尚未显示任务完成，请人工核对。"; return
                    }
                    let candidates = browser.frames.values.filter(\.nextChapter)
                    guard candidates.count == 1 else {
                        continuousVideo = false; status = "视频已结束，无法唯一识别下一节按钮，请手动打开。"; return
                    }
                    _ = try await browser.command("nextChapter", frameID: candidates[0].frameID)
                    hasPlayedVideo = false; videoEndedAt = nil; status = "页面显示完成，正在进入下一节。"
                } else { continuousVideo = false; status = "当前页视频播放完成。" }
            } else if videos.isEmpty && Date().timeIntervalSince(lastVideoAction) > 12 {
                status = "等待页面视频；若课程使用特殊播放器，请手动开始播放。"
            }
        } catch { continuousVideo = false; self.error = error.localizedDescription; status = "连续播放已暂停。" }
    }

    func submitPage() {
        guard !running else { return }
        let candidates = browser.frames.values.filter { $0.submitCount == 1 }
        guard candidates.count == 1 else { error = "无法唯一识别提交按钮，请直接在网页中提交。"; return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "提交当前作业或试卷？"
        let unresolved = results.filter { !$0.filled }.count
        alert.informativeText = "本次识别 \(results.count) 道题，其中 \(unresolved) 道尚未由软件确认填写。请先检查网页中的全部答案。提交可能结束答题且无法撤回。"
        alert.addButton(withTitle: "我已复核，提交此页"); alert.addButton(withTitle: "继续检查")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { _ = try await browser.command("submit", frameID: candidates[0].frameID)
                status = "已点击提交。请核对网站的回执或后续确认；尚未确认提交成功。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importBank() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20_000_000 else { throw StudyError.message("题库文件超过 20 MB。") }
            let file = try JSONDecoder().decode(BankFile.self, from: data)
            guard file.version == 1, file.entries.count <= 50000,
                  file.entries.allSatisfy({ !$0.question.isEmpty && !$0.answers.isEmpty && $0.source.safeURL != nil }) else {
                throw StudyError.message("题库格式不正确，或缺少题干、答案及 HTTPS 来源。")
            }
            let alert = NSAlert(); alert.messageText = "导入 \(file.entries.count) 道题？"
            alert.informativeText = "导入后，题干、题型及选项完全相同的题目可以直接使用这些答案。请确保你已经核对题库内容。此操作会替换当前导入题库。"
            alert.addButton(withTitle: "导入题库"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try data.write(to: supportDirectory.appendingPathComponent("answer-bank.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
            bank.entries = file.entries; bankCount = file.entries.count; status = "已导入 \(bankCount) 道题。"
        } catch { self.error = error.localizedDescription }
    }

    func exportResults() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "HoriStudy-答案核验.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Explicit export only; excludes page URLs, frame IDs, credentials, and browser storage.
            let items: [[String: Any]] = try results.map { row in
                let answer = try row.answer.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()
                return ["question": row.question.stem, "kind": row.question.kind.rawValue,
                        "options": row.question.options.map { ["id": $0.id, "text": $0.text] },
                        "status": row.status, "answer": answer, "filled": row.filled]
            }
            let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic); status = "核验结果已导出。文件包含题目内容，请自行保管。"
        } catch { self.error = error.localizedDescription }
    }
}
