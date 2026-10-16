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
    @Published var keyConfigured = false
    @Published var answerModel: String { didSet { UserDefaults.standard.set(answerModel, forKey: "answerModel") } }
    @Published var reviewModel: String { didSet { UserDefaults.standard.set(reviewModel, forKey: "reviewModel") } }
    @Published var maxQuestions: Int { didSet { UserDefaults.standard.set(maxQuestions, forKey: "maxQuestions") } }
    private var bank = AnswerBank()
    private var worker: Task<Void, Never>?
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
        answerModel = defaults.string(forKey: "answerModel") ?? "gpt-5.4"
        reviewModel = defaults.string(forKey: "reviewModel") ?? "gpt-5.4"
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
        guard !running else { return }
        continuousVideo = false
        scan(); error = ""
        guard !results.isEmpty else { return }
        guard browser.frames.values.allSatisfy({ $0.blocked.isEmpty }) else { return }
        running = true; requestCount = 0; runID = UUID()
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
                let key = try KeychainStore.read()
                keyConfigured = !key.isEmpty
                guard !key.isEmpty else {
                    showSettings = true
                    throw StudyError.message("请先在设置中填入你自己的 OpenAI API 密钥，或导入已核对题库。")
                }
                let settings = AISettings(answerModel: answerModel.trimmingCharacters(in: .whitespacesAndNewlines),
                                          reviewModel: reviewModel.trimmingCharacters(in: .whitespacesAndNewlines))
                guard !settings.answerModel.isEmpty && !settings.reviewModel.isEmpty else { throw StudyError.message("请输入模型名称。") }
                let client = OpenAIClient(key: key, settings: settings)
                update(q.id) { $0.status = "联网查证中" }; status = "第 \(processed) 道：正在检索实际来源。"
                requestCount += 1
                let research = try await client.research(q)
                try Task.checkCancellation()
                update(q.id) { $0.status = "生成答案中" }; status = "已获得检索引用，正在生成答案。"
                requestCount += 1
                let first = try await client.answer(q, research: research, reviewing: false)
                try Task.checkCancellation()
                update(q.id) { $0.status = "第二轮核对中" }; status = "正在用独立请求核对否定词、选项和答案。"
                requestCount += 1
                let second = try await client.answer(q, research: research, reviewing: true)
                checked = AnswerGate.check(first, second, question: q, sources: research.sources)
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
        worker?.cancel(); continuousVideo = false
        for frame in browser.frames.values where !frame.videos.isEmpty {
            Task { _ = try? await browser.command("pauseVideo", frameID: frame.frameID) }
        }
        status = "已暂停。"
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
