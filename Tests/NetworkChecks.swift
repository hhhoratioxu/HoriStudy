import Foundation

final class FixtureProtocol: URLProtocol {
    static var replies: [(Int, [String: Any])] = []
    static var captured: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var saved = request
        if saved.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            saved.httpBody = data
        }
        Self.captured.append(saved)
        guard !Self.replies.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, object) = Self.replies.removeFirst()
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func runNetworkChecks() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let q = StudyQuestion(id: "frame:q", frameID: "frame", signature: "secret-signature", stem: "Test question",
        kind: .single, options: [QuestionOption(id: "o0", label: "A", text: "Answer")], blankCount: 0, unsupported: false, context: "")
    let draft = AnswerDraft(selectedOptionIDs: ["o0"], textAnswers: [], explanation: "fixture", uncertain: false, evidenceIDs: ["s1"])
    let answerText = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
    let research: [String: Any] = ["status": "completed", "output": [
        ["type": "web_search_call", "status": "completed"],
        ["type": "message", "content": [["type": "output_text", "text": "Fixture evidence",
          "annotations": [["type": "url_citation", "url": "https://example.org/reference", "title": "Fixture reference"]]]]]]]
    let answer: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": answerText]]]]]
    FixtureProtocol.replies = [(200, research), (200, answer), (200, answer)]
    FixtureProtocol.captured = []
    let client = OpenAIClient(key: "TEST_NOT_A_REAL_KEY", settings: AISettings(answerModel: "fixture-model", reviewModel: "fixture-review"), session: session)
    let evidence = try await client.research(q)
    let first = try await client.answer(q, research: evidence, reviewing: false)
    let second = try await client.answer(q, research: evidence, reviewing: true)
    check(AnswerGate.check(first, second, question: q, sources: evidence.sources).eligible, "mock transport completes research-answer-review pipeline")
    check(FixtureProtocol.captured.count == 3, "pipeline sends exactly three requests without retries")
    check(FixtureProtocol.captured.allSatisfy { $0.url?.absoluteString == "https://api.openai.com/v1/responses" && $0.httpMethod == "POST" }, "requests use only official Responses endpoint")
    let reviewBody = try JSONSerialization.jsonObject(with: FixtureProtocol.captured[2].httpBody!) as! [String: Any]
    check(reviewBody["model"] as? String == "fixture-review", "independent review uses configured model")
    FixtureProtocol.replies = [(401, ["error": ["message": "PRIVATE_PROVIDER_SENTINEL"]])]
    do { _ = try await client.research(q); check(false, "authentication errors pause pipeline") }
    catch { check(!error.localizedDescription.contains("PRIVATE_PROVIDER_SENTINEL"), "provider error bodies are not exposed") }
    FixtureProtocol.replies = [(429, ["error": ["message": "quota"]])]
    do { _ = try await client.research(q); check(false, "quota errors pause pipeline") }
    catch { check(error.localizedDescription.contains("额度"), "quota errors produce actionable message without retries") }
    print("Mock transport checks completed; no live API request was made.")
}
