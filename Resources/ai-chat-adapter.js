(() => {
  'use strict';
  const hosts = {chatGPT:'chatgpt.com',deepSeek:'chat.deepseek.com',doubao:'www.doubao.com',gemini:'gemini.google.com'};
  let run = null;
  const visible = e => {
    if (!e) return false;
    const style = getComputedStyle(e);
    return style.visibility !== 'hidden' && style.display !== 'none' &&
      (!!(e.offsetWidth || e.offsetHeight || e.getClientRects().length) ||
       (style.display === 'contents' && [...e.children].some(visible)));
  };
  const label = e => (e.getAttribute('aria-label') || e.getAttribute('title') || e.innerText || '').trim();
  function unique(selectors, root = document) {
    for (const selector of selectors) {
      const found = [...root.querySelectorAll(selector)].filter(visible);
      if (found.length === 1) return found[0];
    }
    return null;
  }
  function editor(provider) {
    const specific = {
      chatGPT:['#mobile-composer-prompt','#prompt-textarea'],
      deepSeek:['#chat-input','textarea[placeholder*="DeepSeek"]','textarea[placeholder*="发送消息"]'],
      doubao:['textarea[data-testid="chat_input_input"]','textarea[placeholder*="发消息"]'],
      gemini:['.ql-editor[contenteditable="true"]','[role="textbox"][aria-label*="Gemini"]']
    };
    return unique([...(specific[provider] || []),'textarea:not([readonly]):not([disabled])','[contenteditable="true"][role="textbox"]']);
  }
  const value = e => e ? ('value' in e ? e.value : e.innerText).trim() : '';
  const controls = () => [...document.querySelectorAll('button,[role="button"]')].filter(visible);
  const busy = () => controls().some(e => /^(stop( generating| response| responding)?|停止(生成|回答|输出)?|停止响应)$/i.test(label(e))) ||
    [...document.querySelectorAll('[data-is-streaming="true"],[data-streaming="true"]')].some(visible);
  function messages(provider) {
    const common = ['[data-message-role="assistant"]','[data-message-author-role="assistant"]','[data-role="assistant"]','[data-testid="assistant-message"]'];
    const more = {chatGPT:[],deepSeek:['.ds-markdown'],doubao:['[data-testid="message_text_content"]'],gemini:['model-response']};
    const all = [...document.querySelectorAll([...common,...(more[provider]||[])].join(','))].filter(visible);
    if (provider === 'chatGPT') {
      // The logged-in Chat layout also identifies turns with an accessible heading.
      const headingSelector = 'h1,h2,h3,h4,h5,h6,[role="heading"]';
      const assistantHeading = e => /^(ChatGPT\s*(说|said|says)?\s*[：:]?)$/i.test(e.innerText.trim());
      for (const heading of [...document.querySelectorAll(headingSelector)].filter(visible).filter(assistantHeading)) {
        let scope = heading.parentElement;
        for (let depth=0; scope && depth<4 && !['BODY','HTML'].includes(scope.tagName); depth++,scope=scope.parentElement) {
          if (scope.querySelector('textarea,[contenteditable="true"]') || [...scope.querySelectorAll(headingSelector)].filter(assistantHeading).length !== 1) break;
          if (scope.innerText.trim() !== heading.innerText.trim()) { all.push(scope); break; }
        }
      }
    }
    const distinct = [...new Set(all)];
    return distinct.filter(e => !distinct.some(other => other !== e && other.contains(e)));
  }
  function inspect(provider) {
    if (location.protocol !== 'https:' || location.hostname !== hosts[provider]) return {ok:false,error:'请先在对应服务的官方聊天页面完成登录。'};
    const e = editor(provider);
    const dialogs = [...document.querySelectorAll('dialog,[role="dialog"],[role="alertdialog"],[aria-modal="true"]')].filter(visible);
    if (dialogs.some(d => /清除当前聊天|清除(此|当前)?(聊天|对话)|舍弃.*对话|clear (this |current )?(chat|conversation)|discard.*conversation/i.test(d.innerText))) {
      return {ok:false,kind:'conversationConfirmation',error:'网站要求确认清除当前聊天，软件没有点击清除。请先登录账号，或在网页自行处理后再继续；本轮尚未发送。'};
    }
    if (dialogs.some(d => /验证码|安全验证|verify you are human|captcha|sign in|log in|登录/i.test(d.innerText))) return {ok:false,kind:'authentication',error:'网页要求登录或验证，请在网页中自行完成。'};
    if (!e) return {ok:false,error:'尚未找到聊天输入区。请先完成登录；页面不可用或版式不支持时不会发送。'};
    if ([...document.querySelectorAll('[data-attachment-id],[data-testid="attachment-chip"],[data-testid="file-upload-item"]')].some(visible)) return {ok:false,error:'网页输入区有附件，请先自行处理，避免一起发送。'};
    return {ok:true,draft:!!value(e),busy:busy(),count:messages(provider).length};
  }
  function bodyText(element) {
    const body = element.querySelector('[data-assistant-markdown],.markdown,.ds-markdown,.model-response-text,[data-message-content]') || element;
    const code = [...body.querySelectorAll('pre code')].find(e=>e.innerText.includes('"requestID"'));
    if (code) return code.innerText.trim();
    const clone = body.cloneNode(true);
    clone.querySelectorAll('button,h1,h2,h3,h4,h5,h6,[role="heading"],[data-message-attribution],[data-message-actions]').forEach(e=>e.remove());
    return (clone.innerText || clone.textContent || '').trim();
  }
  function completed(element, provider) {
    if (busy() || element.closest('[aria-busy="true"]') || element.querySelector('[aria-busy="true"]')) return false;
    if (element.hasAttribute('data-message-complete') || element.getAttribute('data-status') === 'completed') return true;
    const all = messages(provider);
    const hasActions = scope => [...(scope.matches('button,[role="button"]') ? [scope] : []),...scope.querySelectorAll('button,[role="button"]')].filter(visible)
      .some(b=> /^(copy( response)?|复制|重新生成(回复|回答)?|regenerate( response)?)$/i.test(label(b)));
    // Some logged-in layouts render answer actions beside the message body.
    // Stay within a single-answer wrapper, never the composer or another turn.
    let scope = element;
    for (let depth = 0; scope && depth < 6 && !['BODY','HTML'].includes(scope.tagName); depth++,scope=scope.parentElement) {
      if (all.filter(e=>scope.contains(e)).length !== 1 || scope.querySelector('textarea,[contenteditable="true"]')) break;
      if (scope.getAttribute('aria-busy') === 'true') return false;
      if (hasActions(scope)) return true;
      // Actions and the composer may share a parent. Inspect only following
      // siblings before another message or input area, rather than that parent.
      let sibling = scope.nextElementSibling;
      for (let distance=0; sibling && distance<10; distance++,sibling=sibling.nextElementSibling) {
        if (sibling.matches('textarea,[contenteditable="true"]') || sibling.querySelector('textarea,[contenteditable="true"]') ||
            all.some(e=>sibling === e || sibling.contains(e)) || sibling.matches('h1,h2,h3,h4,h5,h6,[role="heading"]')) break;
        if (sibling.getAttribute('aria-busy') === 'true') return false;
        if (hasActions(sibling)) return true;
      }
    }
    return false;
  }
  function reply(provider, id) {
    if (!run || run.id !== id || !run.sent) return {ok:false,error:'本次请求状态已失效，不会读取旧回答。'};
    const items = messages(provider).filter(e=>!run.before.has(e));
    const candidates = items.map(e=>({element:e,text:bodyText(e)})).filter(x=>{
      let text = x.text.replace(/^```(?:json)?\s*\n?/i,'').replace(/\s*```$/,'').trim();
      try { const object = JSON.parse(text); return object.requestID === id && object.answer && Object.keys(object).length === 2; }
      catch { return false; }
    });
    if (candidates.length !== 1) return {ok:true,done:false,busy:busy(),observed:items.length,matching:candidates.length};
    const target = candidates[0];
    // A valid nonce alone is not completion. Require the page's completion/actions state.
    const links = [...target.element.querySelectorAll('a[href]')].filter(visible).map(a=>({title:a.innerText.trim()||a.href,url:a.href}));
    return {ok:true,done:completed(target.element,provider),busy:busy(),text:target.text,links,observed:items.length,matching:1};
  }
  async function dispatch(command) {
    const {action,provider,id,prompt} = command;
    const state = inspect(provider);
    if (!state.ok) return state;
    if (action === 'inspect') return state;
    if (action === 'newChat') {
      if (state.draft || state.busy) return {ok:false,error:'网页有尚未发送的草稿或正在生成的回答，请先自行处理。'};
      if (state.count === 0 && ['/', '/app', '/app/', '/chat', '/chat/'].includes(location.pathname)) return {ok:true,fresh:true};
      if (provider === 'chatGPT' && location.pathname.startsWith('/uc/') && controls().some(e=>/^(登录|log in|sign in)$/i.test(label(e)))) {
        return {ok:false,kind:'loginForNewConversation',error:'当前为 ChatGPT 匿名会话，新对话可能要求清除现有聊天。请先登录账号再开始复核；本轮尚未发送。'};
      }
      const choices = [...document.querySelectorAll('button,a,[role="button"]')].filter(visible)
        .filter(e=>/^(new chat|new conversation|new task|新对话|开启新对话|发起新对话|新建对话|新聊天|新任务)(\s|$)/i.test(label(e)));
      // Responsive layouts may show the same action in both navigation bars.
      // Only collapse controls whose accessible name, type and destination agree.
      const identity = e => [e.tagName,e.getAttribute('role') || '',label(e).toLowerCase().replace(/\s+/g,' '),e.getAttribute('href') || ''].join('\n');
      if (!choices.length || !choices.every(e=>identity(e) === identity(choices[0]))) return {ok:false,error:'无法唯一识别“新对话”入口，请在网页手动开启新对话后再试。'};
      choices[0].click(); run = null; return {ok:true,fresh:false};
    }
    if (action === 'prepare') {
      if (state.draft || state.busy || state.count !== 0) return {ok:false,error:'请先完成当前草稿，并开启空白的新对话。'};
      const e = editor(provider); e.focus();
      run = {id,sent:false,before:new Set(messages(provider)),prompt};
      if ('value' in e) {
        const type = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement : HTMLInputElement;
        Object.getOwnPropertyDescriptor(type.prototype,'value').set.call(e,prompt);
        e.dispatchEvent(new Event('input',{bubbles:true}));
      } else {
        const selection = getSelection(); const range = document.createRange();
        range.selectNodeContents(e); selection.removeAllRanges(); selection.addRange(range);
        // WebKit's insertText may apply macOS smart quotes to JSON. Insert escaped
        // plain-text HTML instead, preserving line breaks without interpreting data.
        const escaped = prompt.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>');
        document.execCommand('insertHTML',false,escaped);
        e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertFromPaste',data:prompt}));
      }
      return {ok:value(e) === prompt, error:'网页未接受题目输入，未发送。'};
    }
    if (action === 'send') {
      if (!run || run.id !== id || run.sent) return {ok:false,error:'本题已经发送或状态失效，不会重复发送。'};
      if (state.busy || value(editor(provider)) !== run.prompt) return {ok:false,error:'输入内容发生变化，未发送。'};
      const button = unique(['button[data-testid="send-button"]','button[aria-label="Send message"]','button[aria-label="Send Message"]','button[aria-label="发送消息"]','button[aria-label="发送"]','button.send-button']);
      const options = button ? [button] : controls().filter(e=>/^(send( message)?|发送(消息)?)$/i.test(label(e)));
      if (options.length !== 1 || options[0].disabled || options[0].getAttribute('aria-disabled') === 'true') return {ok:false,retryable:true,error:'发送按钮尚未可用，请核对网页模式和登录状态。'};
      run.sent = true; options[0].click(); return {ok:true,sent:true};
    }
    if (action === 'reply') return reply(provider,id);
    return {ok:false,error:'不支持的网页操作。'};
  }
  Object.defineProperty(globalThis,'HoriChat',{value:Object.freeze({dispatch}),writable:false,configurable:false});
})();
