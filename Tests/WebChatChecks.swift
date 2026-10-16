import AppKit
import WebKit

@MainActor
func runWebChatChecks() async throws {
    let startCount = coreChecks
    let script = try String(contentsOfFile:"Resources/ai-chat-adapter.js",encoding:.utf8)
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:WebAIWorkspace.world))
    let browser = BrowserController(writesDiagnostics:false,configuration:configuration)
    let view = browser.webView
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    window.contentView = view; window.orderBack(nil)
    defer { view.stopLoading(); window.orderOut(nil); window.contentView = nil }
    let html = """
    <!doctype html><html><body><a aria-label="New chat" href="#" onclick="event.preventDefault();document.querySelectorAll('[data-message-role]').forEach(e=>e.remove());">New chat</a>
    <textarea id="mobile-composer-prompt"></textarea><input id="private-login" type="password" value="PRIVATE_PASSWORD_SENTINEL">
    <button aria-label="Send message" onclick="sendFixture()">Send message</button><script>
    window.sendCount=0;window.inputEvents=0;window.holdCompletion=false;
    document.querySelector('textarea').addEventListener('input',()=>inputEvents++);
    function sendFixture(){sendCount++;const input=document.querySelector('textarea');const match=input.value.match(/requestID 原样填写此标识：([^\\n]+)/);const id=match?match[1].trim():input.value;
      input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));const m=document.createElement('li');m.dataset.messageRole='assistant';m.id='reply-'+sendCount;
      const t=document.createElement('div');t.dataset.assistantMarkdown='';t.textContent=JSON.stringify({requestID:id,answer:{selectedOptionIDs:['o1'],textAnswers:[],explanation:'Local fixture only',uncertain:false,evidenceIDs:[]}});m.append(t);document.body.append(m);
      if(!holdCompletion){m.setAttribute('data-message-complete','');const b=document.createElement('button');b.setAttribute('aria-label','Copy response');m.append(b);}}
    </script></body></html>
    """
    view.loadHTMLString(html,baseURL:WebAIProvider.chatGPT.homeURL)
    for _ in 0..<100 {
        if !view.isLoading, (try? await view.callAsyncJavaScript("return typeof globalThis.HoriChat",arguments:[:],in:nil,contentWorld:WebAIWorkspace.world)) as? String == "object" { break }
        try await Task.sleep(nanoseconds:20_000_000)
    }
    func command(_ action:String,id:String="fixture-id",prompt:String="fixture-id",provider:String="chatGPT") async throws -> [String:Any] {
        try await view.callAsyncJavaScript("return await globalThis.HoriChat.dispatch(command)",arguments:["command":["action":action,"provider":provider,"id":id,"prompt":prompt]],in:nil,contentWorld:WebAIWorkspace.world) as? [String:Any] ?? [:]
    }
    check(try await command("inspect")["ok"] as? Bool == true,"web adapter recognizes the real ChatGPT composer selector in WebKit fixture")
    check(try await command("inspect",provider:"gemini")["ok"] as? Bool == false,"web adapter rejects another provider's host")
    _ = try await view.evaluateJavaScript("document.querySelector('textarea').value='existing draft'")
    check(try await command("prepare")["ok"] as? Bool == false,"web automation never overwrites an existing draft")
    _ = try await view.evaluateJavaScript("document.querySelector('textarea').value='';holdCompletion=true")
    check(try await command("prepare")["ok"] as? Bool == true,"web preparation writes and verifies the exact prompt")
    check(try await view.evaluateJavaScript("inputEvents") as? Int == 1,"web preparation dispatches the website input event")
    check(try await command("send")["sent"] as? Bool == true,"web submission clicks the normal send button once")
    check(try await command("send")["ok"] as? Bool == false,"web submission refuses duplicate sends")
    check(try await view.evaluateJavaScript("sendCount") as? Int == 1,"duplicate rejection makes no second website submission")
    check(try await command("reply")["done"] as? Bool == false,"complete-looking JSON without website completion stays pending")
    _ = try await view.evaluateJavaScript("document.querySelector('[data-message-role]').setAttribute('data-message-complete','')")
    let response = try await command("reply")
    let decoded = try WebAnswerFormat.decode(response["text"] as! String,requestID:"fixture-id")
    check(response["done"] as? Bool == true && decoded.selectedOptionIDs == ["o1"],"completed web response is tied to the current request and decoded")
    _ = try await view.evaluateJavaScript("const stop=document.createElement('button');stop.id='stop';stop.setAttribute('aria-label','Stop generating');stop.textContent='Stop generating';document.body.append(stop)")
    check(try await command("reply")["done"] as? Bool == false,"visible stop-generation control blocks completion even when JSON and old completion markers exist")
    _ = try await view.evaluateJavaScript("document.querySelector('#stop').remove()")
    check(try await command("reply",id:"stale")["ok"] as? Bool == false,"web adapter cannot read a response under an unrelated request ID")
    check(try await view.evaluateJavaScript("document.querySelector('#private-login').value") as? String == "PRIVATE_PASSWORD_SENTINEL","web workflow leaves login fields untouched")
    _ = try await command("newChat")
    check(try await command("inspect")["count"] as? Int == 0,"independent web review opens a fresh conversation through the website")
    _ = try await view.evaluateJavaScript("holdCompletion=false")
    let workspace = WebAIWorkspace(); workspace.overrideScript = script; workspace.browserFactory = { _ in browser }
    let q = StudyQuestion(id:"q",frameID:"f",signature:"s",stem:"2+2?",kind:.single,
        options:[QuestionOption(id:"o0",label:"A",text:"3"),QuestionOption(id:"o1",label:"B",text:"4")],blankCount:0,unsupported:false,context:"")
    var sends = 0
    let (first,_) = try await workspace.answer(q,provider:.chatGPT,reviewing:false) { sends += 1 }
    let (second,_) = try await workspace.answer(q,provider:.chatGPT,reviewing:true) { sends += 1 }
    check(first.selectedOptionIDs == ["o1"] && second.selectedOptionIDs == ["o1"] && sends == 2,"production native web workspace completes two fresh correlated fixture conversations")
    print("Web chat checks: \(coreChecks - startCount) passed; local synthetic pages only, no account or subscription was used.")
}
