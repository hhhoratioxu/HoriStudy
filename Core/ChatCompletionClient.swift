import Foundation

final class ChatCompletionClient {
    private let provider: AIProvider
    private let url: URL
    private let key: String
    private let jsonMode: Bool
    private let transport: APITransport

    init(provider: AIProvider, customBaseURL: String = "", jsonMode: Bool = true,
         key: String, session: URLSession? = nil) throws {
        guard provider != .openAI else { throw StudyError.message("OpenAI 请使用 Responses API。") }
        self.provider = provider; self.key = key; self.jsonMode = jsonMode
        url = try provider.baseURL(custom: customBaseURL).appendingPathComponent("chat/completions")
        transport = APITransport(session: session)
    }

    static func answerBody(question: StudyQuestion, research: ResearchResult, model: String,
                           reviewing: Bool, jsonMode: Bool = true) throws -> [String: Any] {
        let responsesBody = try OpenAIClient.answerBody(question: question, research: research, model: model, reviewing: reviewing)
        let schema = String(decoding: try JSONSerialization.data(withJSONObject: OpenAIClient.answerSchema, options: [.sortedKeys]), as: UTF8.self)
        let example = #"{"selectedOptionIDs":[],"textAnswers":[],"explanation":"说明依据或不确定之处","uncertain":true,"evidenceIDs":[]}"#
        var body: [String: Any] = ["model": model, "stream": false, "max_tokens": 8192,
            "messages": [
                ["role": "system", "content": "\(responsesBody["instructions"] as! String) 只输出一个 JSON 对象，不使用 Markdown 代码块。必须精确包含以下 schema 的全部字段，不增加字段。JSON Schema：\(schema)\n格式示例（请根据本题填写）：\(example)"],
                ["role": "user", "content": responsesBody["input"] as! String]
            ]]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        return body
    }

    func answer(_ question: StudyQuestion, research: ResearchResult, model: String, reviewing: Bool) async throws -> AnswerDraft {
        var body = try Self.answerBody(question: question, research: research, model: model, reviewing: reviewing, jsonMode: jsonMode)
        // The official Doubao JSON example disables thinking; no provider-specific fields go to a custom service.
        if provider == .doubao { body["thinking"] = ["type": "disabled"] }
        let root = try await transport.request(url: url, key: key, body: body, provider: provider.title)
        return try Self.parseAnswer(root)
    }

    static func parseAnswer(_ root: [String: Any]) throws -> AnswerDraft {
        guard let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant",
              (message["tool_calls"] as? [Any] ?? []).isEmpty,
              message["function_call"] == nil || message["function_call"] is NSNull,
              message["refusal"] == nil || message["refusal"] is NSNull || message["refusal"] as? String == "",
              let text = message["content"] as? String else {
            throw StudyError.message("模型答案未完整结束、被拒绝或格式不符，已停止自动填写。")
        }
        return try OpenAIClient.decodeAnswer(text)
    }
}
