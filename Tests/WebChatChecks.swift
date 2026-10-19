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
    _ = try await view.evaluateJavaScript("window.fixtureTextarea=document.querySelector('textarea');const rich=document.createElement('div');rich.id='mobile-composer-prompt';rich.contentEditable='true';rich.setAttribute('role','textbox');rich.style.minHeight='40px';fixtureTextarea.replaceWith(rich)")
    let richPrompt = "ASCII \"quotes\" and 'apostrophes'\n{\"requestID\":\"fixture-id\"}\n<svg onload=alert(1)> & literal text"
    check(try await command("prepare",prompt:richPrompt)["ok"] as? Bool == true,"rich web composer preserves ASCII JSON quotes and multiline prompt exactly")
    check(try await view.evaluateJavaScript("document.querySelector('[contenteditable]').innerText") as? String == richPrompt,"rich composer readback matches the original prompt without smart punctuation")
    check(try await view.evaluateJavaScript("document.querySelector('svg') === null") as? Bool == true,"rich composer treats question markup as literal text")
    _ = try await view.evaluateJavaScript("document.querySelector('[contenteditable]').replaceWith(fixtureTextarea);fixtureTextarea.value=''")
    _ = try await command("prepare")
    check(try await command("send")["sent"] as? Bool == true,"web submission clicks the normal send button once")
    check(try await command("send")["ok"] as? Bool == false,"web submission refuses duplicate sends")
    check(try await view.evaluateJavaScript("sendCount") as? Int == 1,"duplicate rejection makes no second website submission")
    check(try await command("reply")["done"] as? Bool == false,"complete-looking JSON without website completion stays pending")
    _ = try await view.evaluateJavaScript("document.querySelector('[data-message-role]').setAttribute('data-message-complete','')")
    let response = try await command("reply")
    let decoded = try WebAnswerFormat.decode(response["text"] as! String,requestID:"fixture-id")
    check(response["done"] as? Bool == true && decoded.selectedOptionIDs == ["o1"],"completed web response is tied to the current request and decoded")
    check(response["observed"] as? Int == 1 && response["matching"] as? Int == 1,"web progress reports correlated response counts without exposing page content")
    _ = try await view.evaluateJavaScript("document.querySelector('[data-message-role]').style.display='contents'")
    check(try await command("reply")["done"] as? Bool == true,"assistant wrappers using display contents remain readable")
    _ = try await view.evaluateJavaScript("const semantic=document.querySelector('[data-message-role]');semantic.style.display='block';semantic.removeAttribute('data-message-role');const heading=document.createElement('h4');heading.textContent='ChatGPT 说：';heading.id='semantic-heading';semantic.prepend(heading);const action=document.createElement('button');action.id='semantic-copy';action.setAttribute('aria-label','复制');semantic.append(action)")
    let semantic = try await command("reply")
    check(semantic["done"] as? Bool == true && (try? WebAnswerFormat.decode(semantic["text"] as? String ?? "",requestID:"fixture-id").selectedOptionIDs) == ["o1"],"logged-in ChatGPT semantic assistant headings correlate and decode the current answer")
    _ = try await view.evaluateJavaScript("document.querySelector('#semantic-heading').parentElement.dataset.messageRole='assistant';document.querySelector('#semantic-heading').remove();document.querySelector('#semantic-copy').remove()")
    _ = try await view.evaluateJavaScript("const message=document.querySelector('[data-message-role]');message.removeAttribute('data-message-complete');const wrapper=document.createElement('section');wrapper.id='answer-wrapper';message.replaceWith(wrapper);wrapper.append(message);const old=document.createElement('section');old.id='old-answer';old.dataset.messageRole='assistant';old.innerHTML='<button aria-label=\"Copy\">Copy</button>';document.body.append(old)")
    check(try await command("reply")["done"] as? Bool == false,"copy controls belonging to an older answer cannot complete the current response")
    _ = try await view.evaluateJavaScript("const copy=document.createElement('button');copy.id='sibling-copy';copy.setAttribute('aria-label','复制');document.querySelector('#answer-wrapper').append(copy)")
    check(try await command("reply")["done"] as? Bool == true,"logged-in layout completion actions may sit beside the current assistant body")
    _ = try await view.evaluateJavaScript("const composer=document.createElement('textarea');composer.id='shared-composer';document.querySelector('#answer-wrapper').append(composer)")
    check(try await command("reply")["done"] as? Bool == true,"response actions before a shared-parent composer still establish completion")
    _ = try await view.evaluateJavaScript("document.querySelector('#answer-wrapper').append(document.querySelector('#sibling-copy'))")
    check(try await command("reply")["done"] as? Bool == false,"actions beyond the composer never complete an earlier message")
    _ = try await view.evaluateJavaScript("document.querySelector('#shared-composer').remove()")
    _ = try await view.evaluateJavaScript("document.querySelector('#answer-wrapper').setAttribute('aria-busy','true')")
    check(try await command("reply")["done"] as? Bool == false,"a busy answer wrapper blocks sibling completion controls")
    _ = try await view.evaluateJavaScript("document.querySelector('#answer-wrapper').removeAttribute('aria-busy');document.querySelector('#old-answer').remove();document.querySelector('#sibling-copy').remove();document.querySelector('[data-message-role]').setAttribute('data-message-complete','')")
    _ = try await view.evaluateJavaScript("const stop=document.createElement('button');stop.id='stop';stop.setAttribute('aria-label','Stop generating');stop.textContent='Stop generating';document.body.append(stop)")
    check(try await command("reply")["done"] as? Bool == false,"visible stop-generation control blocks completion even when JSON and old completion markers exist")
    _ = try await view.evaluateJavaScript("document.querySelector('#stop').remove()")
    check(try await command("reply",id:"stale")["ok"] as? Bool == false,"web adapter cannot read a response under an unrelated request ID")
    check(try await view.evaluateJavaScript("document.querySelector('#private-login').value") as? String == "PRIVATE_PASSWORD_SENTINEL","web workflow leaves login fields untouched")
    _ = try await view.evaluateJavaScript("history.replaceState({},'', '/uc/fixture');const login=document.createElement('button');login.id='fixture-login';login.setAttribute('aria-label','登录');document.body.append(login)")
    let anonymous = try await command("newChat")
    check(anonymous["kind"] as? String == "loginForNewConversation","anonymous ChatGPT review stops before opening a clear-chat confirmation")
    check(try await command("inspect")["count"] as? Int == 1,"anonymous review preserves the first answer")
    _ = try await view.evaluateJavaScript("history.replaceState({},'', '/');document.querySelector('#fixture-login').remove();const dialog=document.createElement('div');dialog.id='fixture-dialog';dialog.setAttribute('aria-modal','true');dialog.textContent='清除当前聊天？若要开始新聊天，系统将舍弃你当前的对话。登录即可保存聊天。';document.body.append(dialog)")
    check(try await command("inspect")["kind"] as? String == "conversationConfirmation","clear-chat confirmation is distinguished from an ordinary unavailable composer")
    check(try await command("send")["ok"] as? Bool == false,"an open clear-chat confirmation prevents another send")
    _ = try await view.evaluateJavaScript("document.querySelector('#fixture-dialog').remove()")
    _ = try await command("newChat")
    check(try await command("inspect")["count"] as? Int == 0,"independent web review opens a fresh conversation through the website")
    _ = try await view.evaluateJavaScript("const repeated=document.querySelector('a').cloneNode(true);repeated.id='repeated-new-chat';document.body.append(repeated);history.replaceState({},'', '/c/fixture')")
    check(try await command("newChat")["ok"] as? Bool == true,"identical responsive new-chat controls resolve to one normal website action")
    _ = try await view.evaluateJavaScript("document.querySelector('#repeated-new-chat').setAttribute('aria-label','New task')")
    check(try await command("newChat")["ok"] as? Bool == false,"different chat and task actions remain ambiguous and are never guessed")
    _ = try await view.evaluateJavaScript("document.querySelector('#repeated-new-chat').setAttribute('aria-label','New chat');document.querySelector('#repeated-new-chat').setAttribute('href','/other')")
    check(try await command("newChat")["ok"] as? Bool == false,"matching new-chat labels with different link destinations remain blocked")
    _ = try await view.evaluateJavaScript("document.querySelector('#repeated-new-chat').remove();history.replaceState({},'', '/')")
    _ = try await view.evaluateJavaScript("holdCompletion=false")
    let workspace = WebAIWorkspace(); workspace.overrideScript = script; workspace.browserFactory = { _ in browser }
    let q = StudyQuestion(id:"q",frameID:"f",signature:"s",stem:"2+2?",kind:.single,
        options:[QuestionOption(id:"o0",label:"A",text:"3"),QuestionOption(id:"o1",label:"B",text:"4")],blankCount:0,unsupported:false,context:"")
    var sends = 0
    let (first,_) = try await workspace.answer(q,provider:.chatGPT,reviewing:false) { sends += 1 }
    let (second,_) = try await workspace.answer(q,provider:.chatGPT,reviewing:true) { sends += 1 }
    check(first.selectedOptionIDs == ["o1"] && second.selectedOptionIDs == ["o1"] && sends == 2,"production native web workspace completes two fresh correlated fixture conversations")
    _ = try await view.evaluateJavaScript("document.querySelector('a').onclick = event => {event.preventDefault();const editor=document.querySelector('textarea');editor.remove();setTimeout(()=>{document.querySelectorAll('[data-message-role]').forEach(e=>e.remove());document.body.prepend(editor)},600)};true")
    let (afterNavigation,_) = try await workspace.answer(q,provider:.chatGPT,reviewing:true)
    check(afterNavigation.selectedOptionIDs == ["o1"],"normal new-chat navigation may briefly hide the composer without being mistaken for a confirmation")
    _ = try await view.evaluateJavaScript("document.querySelector('a').onclick = event => {event.preventDefault();const dialog=document.createElement('div');dialog.setAttribute('role','dialog');dialog.textContent='清除当前聊天？登录即可保存聊天。';document.body.append(dialog)};true")
    let before = Date()
    do { _ = try await workspace.answer(q,provider:.chatGPT,reviewing:true); check(false,"native workspace stops immediately on a new-chat confirmation") }
    catch { check(error.localizedDescription.contains("没有点击清除") && Date().timeIntervalSince(before) < 3,"native workspace surfaces the confirmation without waiting for the generic timeout") }
    check(try await view.evaluateJavaScript("sendCount") as? Int == 4,"blocked native review sends no additional message")
    print("Web chat checks: \(coreChecks - startCount) passed; local synthetic pages only, no account or subscription was used.")
}
