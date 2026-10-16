import Foundation

func runProviderChecks() async throws {
    let startCount = coreChecks
    let q = StudyQuestion(id: "PRIVATE_FRAME:q", frameID: "PRIVATE_FRAME", signature: "PRIVATE_SIGNATURE", stem: "2 + 2?",
        kind: .single, options: [QuestionOption(id: "o0", label: "A", text: "3"), QuestionOption(id: "o1", label: "B", text: "4")],
        blankCount: 0, unsupported: false, context: "PRIVATE_CONTEXT")
    let draft = AnswerDraft(selectedOptionIDs: ["o1"], textAnswers: [], explanation: "FIRST_ANSWER_ONLY", uncertain: false, evidenceIDs: [])
    func chat(_ answer: AnswerDraft) throws -> [String: Any] {
        ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)]]]]
    }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    for provider in [AIProvider.deepSeek, .doubao, .custom] {
        var preferences = AIPreferences()
        preferences.answer = AIModelChoice(provider: provider, model: "fixture-answer")
        preferences.review = AIModelChoice(provider: provider, model: "fixture-review")
        preferences.useWebResearch = false
        preferences.customBaseURL = "https://custom.example.test/v1/"
        preferences.customJSONMode = false
        FixtureProtocol.captured = []; FixtureProtocol.replies = [(200, try chat(draft)), (200, try chat(draft))]
        let result = try await AnswerPipeline(preferences: preferences, keys: [provider: "FIXTURE_\(provider.rawValue)"], session: session).run(q)
        check(!result.eligible && result.verification.contains("未联网"), "\(provider.rawValue) alone returns a clearly labelled draft")
        let requests = FixtureProtocol.captured
        check(requests.count == 2 && requests.allSatisfy { $0.url == (try? provider.baseURL(custom: preferences.customBaseURL).appendingPathComponent("chat/completions")) }, "\(provider.rawValue) uses its own endpoint without requiring OpenAI")
        check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer FIXTURE_\(provider.rawValue)" && !$0.httpShouldHandleCookies }, "\(provider.rawValue) uses only its scoped key and excludes browser cookies")
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        check(body["model"] as? String == "fixture-review", "\(provider.rawValue) selects the independent review model")
        if provider == .custom { check(body["response_format"] == nil && body["thinking"] == nil, "custom service can omit JSON mode and provider-specific extensions") }
        else { check((body["response_format"] as? [String:String])?["type"] == "json_object", "\(provider.rawValue) requests documented JSON Object output") }
    }
    var mixed = AIPreferences(); mixed.answer = AIModelChoice(provider: .deepSeek); mixed.review = AIModelChoice(provider: .doubao)
    var cited = draft; cited.evidenceIDs = ["s1"]
    let research: [String:Any] = ["status":"completed","output":[
        ["type":"web_search_call","status":"completed"],
        ["type":"message","content":[["type":"output_text","text":"RESEARCH_DATA_ONLY","annotations":[["type":"url_citation","title":"Fixture","url":"https://example.org/source"]]]]]]]
    FixtureProtocol.captured = []; FixtureProtocol.replies = [(200,research),(200,try chat(cited)),(200,try chat(cited))]
    let result = try await AnswerPipeline(preferences: mixed, keys: [.openAI:"OPENAI_FIXTURE",.deepSeek:"DEEPSEEK_FIXTURE",.doubao:"DOUBAO_FIXTURE"], session: session).run(q)
    check(result.eligible, "OpenAI research can support DeepSeek answering and Doubao independent review")
    let requests = FixtureProtocol.captured
    check(requests.map { $0.url!.host! } == ["api.openai.com","api.deepseek.com","ark.cn-beijing.volces.com"], "mixed pipeline routes to three official hosts")
    check(requests.map { $0.value(forHTTPHeaderField:"Authorization")! } == ["Bearer OPENAI_FIXTURE","Bearer DEEPSEEK_FIXTURE","Bearer DOUBAO_FIXTURE"], "mixed pipeline never shares one provider credential with another")
    let review = String(decoding: requests[2].httpBody!, as: UTF8.self)
    check(review.contains("RESEARCH_DATA_ONLY") && !review.contains("FIRST_ANSWER_ONLY") && !review.contains("PRIVATE_"), "cross-provider review receives evidence without the first answer or browser identifiers")
    FixtureProtocol.captured = []; FixtureProtocol.replies = []
    do { _ = try await AnswerPipeline(preferences: mixed, keys: [.openAI:"fixture",.deepSeek:"fixture"], session: session).run(q); check(false,"missing review key stops before spending") }
    catch { check(FixtureProtocol.captured.isEmpty,"missing review key stops before any request") }
    check(try CredentialScope(provider:.openAI).service == "com.hhhoratioxu.HoriStudy.openai" && CredentialScope(provider:.openAI).account == "api-key", "existing OpenAI keychain identity remains compatible")
    let customA = try CredentialScope(provider:.custom,customBaseURL:"https://CUSTOM.example.test:443/v1/")
    let customB = try CredentialScope(provider:.custom,customBaseURL:"https://custom.example.test/v1")
    let customC = try CredentialScope(provider:.custom,customBaseURL:"https://other.example.test/v1")
    check(customA == customB && customA != customC, "custom keys are isolated by normalized exact Base URL")
    for value in ["http://example.org/v1","https://user:key@example.org/v1","https://example.org/v1?key=secret","https://example.org/v1/chat/completions"] {
        rejects("invalid custom URL rejected: \(value.hasPrefix("http:") ? "insecure scheme" : "credentials, query or full endpoint")") { _ = try AIProvider.custom.baseURL(custom:value) }
    }
    let blocker = APIRedirectBlocker(); var blocked = false
    blocker.urlSession(session, task: session.dataTask(with: URL(string:"https://example.org")!),
        willPerformHTTPRedirection: HTTPURLResponse(url:URL(string:"https://example.org")!,statusCode:302,httpVersion:nil,headerFields:nil)!,
        newRequest:URLRequest(url:URL(string:"https://other.example.org")!)) { blocked = $0 == nil }
    check(blocked,"API delegate refuses redirected credential forwarding")
    var bad = try chat(draft); bad["choices"] = [["finish_reason":"length","message":["role":"assistant","content":"{}"]]]
    rejects("truncated chat response cannot become an answer") { _ = try ChatCompletionClient.parseAnswer(bad) }
    rejects("extra answer fields are rejected even without server schema enforcement") { _ = try OpenAIClient.decodeAnswer(#"{"selectedOptionIDs":[],"textAnswers":[],"explanation":"x","uncertain":false,"evidenceIDs":[],"extra":1}"#) }
    let prompt = try WebAnswerFormat.prompt(question:q,requestID:"nonce",reviewing:true)
    check(!prompt.contains("PRIVATE_") && prompt.contains("nonce"), "web prompt excludes page identifiers and binds a request nonce")
    let envelope = String(decoding: try JSONSerialization.data(withJSONObject:["requestID":"nonce","answer":JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))]), as:UTF8.self)
    check(try WebAnswerFormat.decode("```json\n\(envelope)\n```",requestID:"nonce") == draft,"web parser accepts a matching complete fenced JSON answer")
    rejects("web parser rejects stale or unrelated request nonce") { _ = try WebAnswerFormat.decode(envelope,requestID:"other") }
    let defaults = WebAIPreferences()
    check(!WebAnswerFormat.check(draft,draft,question:q,preferences:defaults,sources:[]).eligible,"web agreement stays a draft by default")
    var automatic = defaults; automatic.autoFillAgreedDrafts = true
    check(WebAnswerFormat.check(draft,draft,question:q,preferences:automatic,sources:[]).eligible,"explicit preference permits filling an agreed web draft")
    var wrong = draft; wrong.selectedOptionIDs = ["o0"]
    check(!WebAnswerFormat.check(draft,wrong,question:q,preferences:automatic,sources:[]).eligible,"web disagreement still blocks opted-in automatic filling")
    print("Provider and web-format checks: \(coreChecks - startCount) passed; mocked API transport only.")
}
