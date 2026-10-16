import Foundation

var coreChecks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { print("FAIL: \(label)"); exit(1) }
    coreChecks += 1; print("PASS: \(label)")
}
func rejects(_ label: String, _ action: () throws -> Void) {
    do { try action(); print("FAIL: \(label)"); exit(1) }
    catch { coreChecks += 1; print("PASS: \(label)") }
}

func runCoreChecks() throws {
    let source = Citation(id: "s1", title: "Reference", url: "https://example.org/reference")
    check(StudyNavigationPolicy.trusted("mooc1.chaoxing.com"), "platform subdomain trusted")
    check(!StudyNavigationPolicy.trusted("chaoxing.com.evil.example") && !StudyNavigationPolicy.trusted("evilchaoxing.com"), "lookalike domains rejected")
    check(StudyNavigationPolicy.decide(url: URL(string: "javascript:void(0)")!, sourceHost: "passport2.chaoxing.com", mainFrame: true) == .allow, "official login JavaScript links work")
    check(StudyNavigationPolicy.decide(url: URL(string: "javascript:alert(1)")!, sourceHost: "example.org", mainFrame: true) == .cancel, "untrusted JavaScript navigation rejected")
    check(StudyNavigationPolicy.decide(url: URL(string: "chaoxing://login")!, sourceHost: "passport2.chaoxing.com", mainFrame: true) == .externalApp("chaoxing"), "mobile deep link has nonfatal handling")
    check(StudyNavigationPolicy.decide(url: URL(string: "http://i.chaoxing.com:80/path?q=1")!, sourceHost: "passport2.chaoxing.com", mainFrame: true) == .upgrade(URL(string: "https://i.chaoxing.com/path?q=1")!), "legacy official links upgrade to HTTPS")
    check(StudyNavigationPolicy.decide(url: URL(string: "file:///etc/passwd")!, sourceHost: "passport2.chaoxing.com", mainFrame: true) == .cancel, "web navigation cannot open local files")
    check(StudyNavigationPolicy.decide(url: URL(string: "https://user:password@example.org/")!, sourceHost: "passport2.chaoxing.com", mainFrame: true) == .cancel, "credential-bearing navigation rejected")
    let q = StudyQuestion(id: "private-frame:q1", frameID: "private-frame", signature: "private-signature",
        stem: "2 + 2 = ?", kind: .single,
        options: [QuestionOption(id: "o0", label: "A", text: "3"), QuestionOption(id: "o1", label: "B", text: "4")],
        blankCount: 0, unsupported: false, context: "作业")
    let good = AnswerDraft(selectedOptionIDs: ["o1"], textAnswers: [], explanation: "Arithmetic", uncertain: false, evidenceIDs: ["s1"])
    check(AnswerGate.check(good, good, question: q, sources: [source]).eligible, "valid cited agreement accepted")
    var wrong = good; wrong.selectedOptionIDs = ["o0"]
    check(!AnswerGate.check(good, wrong, question: q, sources: [source]).eligible, "disagreement stops autofill")
    wrong.selectedOptionIDs = ["o0", "o1"]
    check(AnswerGate.validate(wrong, for: q) != nil, "single choice rejects two options")
    wrong.selectedOptionIDs = ["o9"]
    check(AnswerGate.validate(wrong, for: q) != nil, "unknown option rejected")
    wrong = good; wrong.uncertain = true
    check(!AnswerGate.check(good, wrong, question: q, sources: [source]).eligible, "uncertainty in either pass stops autofill")
    wrong = good; wrong.evidenceIDs = ["invented"]
    check(!AnswerGate.check(good, wrong, question: q, sources: [source]).eligible, "fabricated citation rejected")
    check(!AnswerGate.check(good, good, question: q, sources: []).eligible, "missing citations rejected")
    check(Citation(id: "x", title: "x", url: "javascript:alert(1)").safeURL == nil, "unsafe citation scheme rejected")
    let imageQ = StudyQuestion(id: q.id, frameID: q.frameID, signature: q.signature, stem: q.stem,
        kind: q.kind, options: q.options, blankCount: 0, unsupported: true, context: "")
    check(AnswerGate.validate(good, for: imageQ) != nil, "image questions require manual review")
    let multi = StudyQuestion(id: q.id, frameID: q.frameID, signature: q.signature, stem: q.stem,
        kind: .multiple, options: q.options, blankCount: 0, unsupported: false, context: "")
    var m1 = good; m1.selectedOptionIDs = ["o0", "o1"]
    var m2 = m1; m2.selectedOptionIDs.reverse()
    check(AnswerGate.check(m1, m2, question: multi, sources: [source]).eligible, "multiple choice ignores answer order")
    m2.selectedOptionIDs = ["o1", "o1"]
    check(AnswerGate.validate(m2, for: multi) != nil, "duplicate choices rejected")
    let fill = StudyQuestion(id: "fill", frameID: "private", signature: "fill", stem: "units", kind: .fill,
        options: [], blankCount: 2, unsupported: false, context: "")
    let f1 = AnswerDraft(selectedOptionIDs: [], textAnswers: ["10 m", "-2"], explanation: "", uncertain: false, evidenceIDs: ["s1"])
    var f2 = f1; f2.textAnswers = ["10 m", "2"]
    check(!AnswerGate.check(f1, f2, question: fill, sources: [source]).eligible, "text normalization preserves negative signs")
    f2.textAnswers = ["10 m"]
    check(AnswerGate.validate(f2, for: fill) != nil, "blank count enforced")
    let entry = BankEntry(question: q.stem, kind: .single, options: ["4", "3"], answers: ["4"], explanation: "Arithmetic", source: source)
    let bank = AnswerBank(entries: [entry])
    if case .found(let answer) = bank.match(q) { check(answer.draft.selectedOptionIDs == ["o1"], "bank matches option content after shuffle") }
    else { check(false, "bank matches option content after shuffle") }
    let conflicting = BankEntry(question: q.stem, kind: .single, options: ["3", "4"], answers: ["3"], explanation: "", source: source)
    if case .conflict = AnswerBank(entries: [entry, conflicting]).match(q) { check(true, "conflicting bank entries stop autofill") }
    else { check(false, "conflicting bank entries stop autofill") }
    let different = BankEntry(question: q.stem, kind: .single, options: ["3", "5"], answers: ["5"], explanation: "", source: source)
    if case .none = AnswerBank(entries: [different]).match(q) { check(true, "bank requires complete exact option set") }
    else { check(false, "bank requires complete exact option set") }
    let body = try OpenAIClient.researchBody(question: q, model: "test-model")
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    check(!raw.contains("private-frame") && !raw.contains("private-signature"), "API request excludes internal frame data")
    check(body["store"] as? Bool == false && body["tool_choice"] as? String == "required", "research disables storage and requires search")
    var envelope: [String: Any] = ["status": "completed", "output": [
        ["type": "web_search_call", "status": "completed"],
        ["type": "message", "content": [["type": "output_text", "text": "Evidence",
         "annotations": [["type": "url_citation", "url": source.url, "title": source.title]]]]]
    ]]
    let research = try OpenAIClient.parseResearch(envelope)
    check(research.sources.count == 1 && research.sources[0].id == "s1", "research reads actual tool annotations")
    envelope["status"] = "incomplete"
    rejects("incomplete response rejected") { _ = try OpenAIClient.parseResearch(envelope) }
    envelope = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "no search"]]]]]
    rejects("answer without completed search rejected") { _ = try OpenAIClient.parseResearch(envelope) }
    envelope = ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "no"]]]]]
    rejects("provider refusal rejected") { _ = try OpenAIClient.outputText(envelope) }
    let structured = try OpenAIClient.answerBody(question: q, research: research, model: "test", reviewing: true)
    let structuredRaw = String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)
    check(!structuredRaw.contains("private-frame"), "review excludes browser identifiers")
    print("Core checks: \(coreChecks) passed")
}
