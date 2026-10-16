import Foundation

enum AIStage { case research, answer, review }

struct AnswerPipeline {
    let preferences: AIPreferences
    let keys: [AIProvider: String]
    var session: URLSession? = nil

    func run(_ question: StudyQuestion, progress: (AIStage) async -> Void = { _ in }) async throws -> CheckedAnswer {
        try preferences.validate()
        for provider in preferences.requiredProviders {
            guard let key = keys[provider], !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw StudyError.message("请在设置中保存 \(provider.title) 的 API 密钥。")
            }
        }
        guard !question.unsupported, question.kind != .unknown else {
            throw StudyError.message("题目内容无法完整读取，未发送给 AI。")
        }
        try Task.checkCancellation()
        let research: ResearchResult
        if preferences.useWebResearch {
            await progress(.research)
            research = try await OpenAIClient(key: keys[.openAI]!,
                settings: AISettings(answerModel: preferences.researchModel, reviewModel: preferences.researchModel), session: session).research(question)
        } else {
            research = ResearchResult(text: "未进行联网检索，没有经过核对的外部资料。请根据已有知识给出答案草稿；证据不足时标明 uncertain。evidenceIDs 必须为空，不得编造来源。", sources: [])
        }
        try Task.checkCancellation()
        await progress(.answer)
        let first = try await answer(question, research: research, choice: preferences.answer, reviewing: false)
        try Task.checkCancellation()
        await progress(.review)
        let second = try await answer(question, research: research, choice: preferences.review, reviewing: true)
        try Task.checkCancellation()
        var result = AnswerGate.check(first, second, question: question, sources: research.sources,
                                      requireSources: preferences.useWebResearch)
        result.attribution = "作答：\(preferences.answer.provider.title) / \(preferences.answer.model)；复核：\(preferences.review.provider.title) / \(preferences.review.model)"
        return result
    }

    private func answer(_ question: StudyQuestion, research: ResearchResult, choice: AIModelChoice, reviewing: Bool) async throws -> AnswerDraft {
        if choice.provider == .openAI {
            return try await OpenAIClient(key: keys[.openAI]!,
                settings: AISettings(answerModel: choice.model, reviewModel: choice.model), session: session)
                .answer(question, research: research, reviewing: reviewing)
        }
        return try await ChatCompletionClient(provider: choice.provider, customBaseURL: preferences.customBaseURL,
            jsonMode: choice.provider == .custom ? preferences.customJSONMode : true,
            key: keys[choice.provider]!, session: session)
            .answer(question, research: research, model: choice.model, reviewing: reviewing)
    }
}
