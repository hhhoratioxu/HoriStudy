import Foundation

enum QuestionKind: String, Codable, CaseIterable {
    case single, multiple, truefalse, fill, essay, unknown
    var title: String {
        switch self {
        case .single: return "单选"
        case .multiple: return "多选"
        case .truefalse: return "判断"
        case .fill: return "填空"
        case .essay: return "简答"
        case .unknown: return "未识别"
        }
    }
    var isChoice: Bool { [.single, .multiple, .truefalse].contains(self) }
}

struct QuestionOption: Codable, Hashable, Identifiable {
    let id: String
    let label: String
    let text: String
}

struct StudyQuestion: Codable, Identifiable, Hashable {
    let id: String
    let frameID: String
    let signature: String
    let stem: String
    let kind: QuestionKind
    let options: [QuestionOption]
    let blankCount: Int
    let unsupported: Bool
    let context: String
}

struct Citation: Codable, Hashable, Identifiable {
    var id: String
    let title: String
    let url: String
    var safeURL: URL? {
        guard let value = URL(string: url), value.scheme == "https", value.host != nil,
              value.user == nil, value.password == nil else { return nil }
        return value
    }
}

struct AnswerDraft: Codable, Equatable {
    var selectedOptionIDs: [String]
    var textAnswers: [String]
    var explanation: String
    var uncertain: Bool
    var evidenceIDs: [String]
}

struct CheckedAnswer: Codable {
    let draft: AnswerDraft
    let sources: [Citation]
    let verification: String
    let eligible: Bool
    let reason: String
}

enum AnswerGate {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func validate(_ answer: AnswerDraft, for question: StudyQuestion) -> String? {
        if question.unsupported { return "题目包含图片、公式图片或无法读取的内容，请人工核对。" }
        if question.kind == .unknown { return "题型未识别，已停止自动填写。" }
        if answer.uncertain { return "模型报告证据不足或存在歧义。" }
        if question.kind.isChoice {
            let ids = Set(answer.selectedOptionIDs)
            if ids.isEmpty || ids.count != answer.selectedOptionIDs.count { return "选项为空或重复。" }
            if !ids.isSubset(of: Set(question.options.map(\.id))) { return "答案引用了不存在的选项。" }
            if question.kind != .multiple && ids.count != 1 { return "单选或判断题只能选择一个选项。" }
            if !answer.textAnswers.isEmpty { return "选择题返回了不匹配的文本答案。" }
        } else {
            if !answer.selectedOptionIDs.isEmpty { return "文本题返回了不匹配的选项答案。" }
            let expected = question.kind == .essay ? 1 : question.blankCount
            if expected < 1 || answer.textAnswers.count != expected ||
                answer.textAnswers.contains(where: { normalized($0).isEmpty }) {
                return "答案数量与页面输入框不匹配。"
            }
        }
        return nil
    }

    static func check(_ first: AnswerDraft, _ second: AnswerDraft,
                      question: StudyQuestion, sources: [Citation]) -> CheckedAnswer {
        var reason = validate(first, for: question) ?? validate(second, for: question)
        if reason == nil {
            let same = question.kind.isChoice ?
                Set(first.selectedOptionIDs) == Set(second.selectedOptionIDs) :
                first.textAnswers.map(normalized) == second.textAnswers.map(normalized)
            if !same { reason = "两轮答案不一致，请人工核对。" }
        }
        let known = Set(sources.filter { $0.safeURL != nil }.map(\.id))
        let firstIDs = Set(first.evidenceIDs)
        let secondIDs = Set(second.evidenceIDs)
        if reason == nil && (firstIDs.isEmpty || secondIDs.isEmpty ||
                            !firstIDs.isSubset(of: known) || !secondIDs.isSubset(of: known)) {
            reason = "答案缺少可核对的检索来源，或引用了不存在的来源。"
        }
        return CheckedAnswer(draft: first, sources: sources, verification: "两轮一致 · 检索有来源",
                             eligible: reason == nil,
                             reason: reason ?? "两次独立请求给出一致答案。相同模型及相同来源仍可能同时出错。")
    }
}

struct BankFile: Codable { let version: Int; let entries: [BankEntry] }
struct BankEntry: Codable {
    let question: String
    let kind: QuestionKind
    let options: [String]
    let answers: [String]
    let explanation: String
    let source: Citation
}

enum BankMatch { case none, conflict(String), found(CheckedAnswer) }

struct AnswerBank {
    var entries: [BankEntry] = []

    func match(_ question: StudyQuestion) -> BankMatch {
        guard !question.unsupported else { return .none }
        let matches = entries.filter {
            AnswerGate.normalized($0.question) == AnswerGate.normalized(question.stem) &&
            $0.kind == question.kind &&
            $0.options.map(AnswerGate.normalized).sorted() == question.options.map { AnswerGate.normalized($0.text) }.sorted()
        }
        guard !matches.isEmpty else { return .none }
        let candidates: [AnswerDraft] = matches.map { entry in
            let ids: [String] = question.kind.isChoice ? entry.answers.compactMap { text -> String? in
                let opts = question.options.filter { AnswerGate.normalized($0.text) == AnswerGate.normalized(text) }
                return opts.count == 1 ? opts[0].id : nil
            } : []
            return AnswerDraft(selectedOptionIDs: ids, textAnswers: question.kind.isChoice ? [] : entry.answers,
                               explanation: entry.explanation, uncertain: ids.count != entry.answers.count && question.kind.isChoice,
                               evidenceIDs: [entry.source.id])
        }
        guard let first = candidates.first else { return .none }
        if candidates.contains(where: { candidate in
            Set(candidate.selectedOptionIDs) != Set(first.selectedOptionIDs) ||
            candidate.textAnswers.map(AnswerGate.normalized) != first.textAnswers.map(AnswerGate.normalized)
        }) { return .conflict("导入题库对这道题包含相互冲突的答案。") }
        if let reason = AnswerGate.validate(first, for: question) { return .conflict(reason) }
        return .found(CheckedAnswer(draft: first, sources: matches.map(\.source), verification: "导入题库精确匹配",
                                    eligible: true, reason: "题干、题型及完整选项相同，按选项内容匹配；题库内容由导入者负责核对。"))
    }
}

struct VideoState: Codable, Identifiable {
    let id: String
    let current: Double
    let duration: Double
    let paused: Bool
    let ended: Bool
}

struct FrameSnapshot: Codable {
    let frameID: String
    let title: String
    let questions: [StudyQuestion]
    let videos: [VideoState]
    let blocked: String
    let nextQuestion: Bool
    let nextChapter: Bool
    let submitCount: Int
    let completion: String
}

enum StudyError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
