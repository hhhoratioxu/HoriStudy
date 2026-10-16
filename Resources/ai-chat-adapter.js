(() => {
  'use strict';
  const hosts = {chatGPT:'chatgpt.com',deepSeek:'chat.deepseek.com',doubao:'www.doubao.com',gemini:'gemini.google.com'};
  let run = null;
  const visible = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length) && getComputedStyle(e).visibility !== 'hidden';
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
    !!document.querySelector('[data-is-streaming="true"],[data-streaming="true"]');
  function messages(provider) {
    const common = ['[data-message-role="assistant"]','[data-message-author-role="assistant"]','[data-role="assistant"]','[data-testid="assistant-message"]'];
    const more = {chatGPT:[],deepSeek:['.ds-markdown'],doubao:['[data-testid="message_text_content"]'],gemini:['model-response']};
    const all = [...document.querySelectorAll([...common,...(more[provider]||[])].join(','))].filter(visible);
    return all.filter(e => !all.some(other => other !== e && other.contains(e)));
  }
  function inspect(provider) {
    if (location.protocol !== 'https:' || location.hostname !== hosts[provider]) return {ok:false,error:'请先在对应服务的官方聊天页面完成登录。'};
    const e = editor(provider);
    const dialogs = [...document.querySelectorAll('[role="dialog"],[role="alertdialog"]')].filter(visible);
    if (dialogs.some(d => /验证码|安全验证|verify you are human|captcha|sign in|log in|登录/i.test(d.innerText))) return {ok:false,error:'网页要求登录或验证，请在网页中自行完成。'};
    if (!e) return {ok:false,error:'尚未找到聊天输入区。请先完成登录；页面不可用或版式不支持时不会发送。'};
    if ([...document.querySelectorAll('[data-attachment-id],[data-testid="attachment-chip"],[data-testid="file-upload-item"]')].some(visible)) return {ok:false,error:'网页输入区有附件，请先自行处理，避免一起发送。'};
    return {ok:true,draft:!!value(e),busy:busy(),count:messages(provider).length};
  }
  function bodyText(element) {
    const body = element.querySelector('[data-assistant-markdown],.markdown,.ds-markdown,.model-response-text,[data-message-content]') || element;
    const code = [...body.querySelectorAll('pre code')].find(e=>e.innerText.includes('"requestID"'));
    if (code) return code.innerText.trim();
    const clone = body.cloneNode(true);
    clone.querySelectorAll('button,[data-message-attribution],[data-message-actions]').forEach(e=>e.remove());
    return (clone.innerText || clone.textContent || '').trim();
  }
  function completed(element) {
    if (busy() || element.querySelector('[aria-busy="true"]')) return false;
    return element.hasAttribute('data-message-complete') || element.getAttribute('data-status') === 'completed' ||
      [...element.querySelectorAll('button,[role="button"]')].some(b=> /copy response|copy|复制|重新生成|regenerate/i.test(label(b)));
  }
  function reply(provider, id) {
    if (!run || run.id !== id || !run.sent) return {ok:false,error:'本次请求状态已失效，不会读取旧回答。'};
    const items = messages(provider).filter(e=>!run.before.has(e));
    const candidates = items.map(e=>({element:e,text:bodyText(e)})).filter(x=>{
      let text = x.text.replace(/^```(?:json)?\s*\n?/i,'').replace(/\s*```$/,'').trim();
      try { const object = JSON.parse(text); return object.requestID === id && object.answer && Object.keys(object).length === 2; }
      catch { return false; }
    });
    if (candidates.length !== 1) return {ok:true,done:false,busy:busy()};
    const target = candidates[0];
    // A valid nonce alone is not completion. Require the page's completion/actions state.
    const links = [...target.element.querySelectorAll('a[href]')].filter(visible).map(a=>({title:a.innerText.trim()||a.href,url:a.href}));
    return {ok:true,done:completed(target.element),text:target.text,links};
  }
  async function dispatch(command) {
    const {action,provider,id,prompt} = command;
    const state = inspect(provider);
    if (!state.ok) return state;
    if (action === 'inspect') return state;
    if (action === 'newChat') {
      if (state.draft || state.busy) return {ok:false,error:'网页有尚未发送的草稿或正在生成的回答，请先自行处理。'};
      if (state.count === 0 && ['/', '/app', '/app/', '/chat', '/chat/'].includes(location.pathname)) return {ok:true,fresh:true};
      const choices = [...document.querySelectorAll('button,a,[role="button"]')].filter(visible)
        .filter(e=>/^(new chat|new conversation|new task|新对话|开启新对话|发起新对话|新建对话|新聊天|新任务)(\s|$)/i.test(label(e)));
      if (choices.length !== 1) return {ok:false,error:'无法唯一识别“新对话”入口，请在网页手动开启新对话后再试。'};
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
        document.execCommand('insertText',false,prompt);
        e.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:prompt}));
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
