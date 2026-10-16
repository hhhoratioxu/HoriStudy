/* HoriStudy — original DOM adapter. Runs in a private WebKit content world. */
(() => {
  'use strict';
  if (globalThis.HoriStudy) return;
  const testMode = typeof HORI_TEST_MODE !== 'undefined' && HORI_TEST_MODE === true;
  const host = location.hostname.toLowerCase();
  const allowed = testMode || (location.protocol === 'https:' &&
    ['chaoxing.com', 'xueyinonline.com'].some(d => host === d || host.endsWith('.' + d)));
  if (!allowed) return;
  const frameID = crypto.randomUUID();
  const ids = new WeakMap();
  const nodes = new Map();
  const qSelector = '.TiMu, .mark_table, .mark_item, .questionLi, .question-item, .singleQues, [data-hori-question]';
  const clean = value => String(value || '').normalize('NFC').replace(/\s+/g, ' ').trim();
  const visible = el => !!el && el.isConnected && el.getClientRects().length > 0 &&
    getComputedStyle(el).visibility !== 'hidden' && getComputedStyle(el).display !== 'none';
  const uid = el => {
    if (!ids.has(el)) ids.set(el, crypto.randomUUID());
    const id = ids.get(el); nodes.set(id, el); return id;
  };
  const text = el => clean(el?.innerText || el?.textContent || '');
  const queryOne = (root, selectors) => {
    for (const selector of selectors) { const el = root.querySelector(selector); if (el) return el; }
    return null;
  };
  const queryGroup = (root, selectors) => {
    for (const selector of selectors) {
      const list = [...root.querySelectorAll(selector)];
      if (list.length) return list;
    }
    return [];
  };

  function blocker() {
    const selector = '[role="dialog"], .layui-layer, .maskDiv, .yidun_popup, .captcha, #captcha, .verify-wrap, .face-recognition, .vertify';
    for (const el of document.querySelectorAll(selector)) {
      if (!visible(el)) continue;
      if (/验证码|拖动.*滑块|安全验证|人脸识别|摄像头|监考|环境检测/.test(text(el)))
        return '页面要求验证或监考操作，请在网页中亲自完成后再启动。';
    }
    if ([...document.querySelectorAll('input[type="password"]')].some(visible))
      return '请先在网页中登录学习通。';
    if ([...document.querySelectorAll('#videoquiz-submit, .ans-videoquiz-opt')].some(visible))
      return '视频出现了弹出问题，请先在网页中完成后再启动连续播放。';
    return '';
  }

  function parseQuestion(root) {
    const title = queryOne(root, ['[data-question-stem]', '.mark_name', '.Zy_TItle .clearfix', '.Zy_TItle', '.question-title', '.stem', '.qtContent', 'h3']);
    if (!title || !visible(root)) return null;
    let stem = text(title).replace(/^\s*\d+\s*[、．]\s*|^\s*\d+\.\s+/, '')
      .replace(/^[（(【\[]\s*(?:单选题|多选题|判断题|填空题|简答题)[^）)】\]]*[）)】\]]\s*/, '');
    stem = clean(stem);
    if (!stem || stem.length > 14000) return null;
    let choices = queryGroup(root, ['[data-question-option]', '.mark_letter > li', '.Zy_ulTop > li',
      '.answerList > li', '.question-option', '.answer_p', 'label:has(input[type="radio"]), label:has(input[type="checkbox"])']);
    if (!choices.length) {
      choices = [...root.querySelectorAll('input[type="radio"], input[type="checkbox"]')].map(input =>
        input.closest('li') || input.closest('label') || (input.id && root.querySelector(`label[for="${CSS.escape(input.id)}"]`)) || input.parentElement);
    }
    choices = [...new Set(choices)].filter(el => visible(el));
    let options = choices.map((el, index) => {
      const label = String.fromCharCode(65 + index);
      let content = text(el).replace(/^[A-Z]\s*[.、．:：)）]\s*/, '');
      if (!content && el.querySelector('input')?.value) content = el.querySelector('input').value;
      return { id: 'o' + index, label, text: content };
    });
    let fields = queryGroup(root, ['textarea', '[contenteditable="true"]', 'input[type="text"]']);
    fields = fields.filter(visible);
    const typeInput = queryOne(root, ['input[id^="answertype"]', 'input[name^="answertype"]', 'input[name^="type"]', '[data-question-type]']);
    const explicit = root.getAttribute('data-question-type') || typeInput?.getAttribute('data-question-type') || typeInput?.value || '';
    const heading = text(title);
    let kind = 'unknown';
    const typeMap = { '0': 'single', '1': 'multiple', '2': 'fill', '3': 'truefalse', '4': 'essay',
      single: 'single', multiple: 'multiple', truefalse: 'truefalse', fill: 'fill', essay: 'essay' };
    if (explicit) kind = typeMap[explicit] || 'unknown';
    else if (/多选/.test(heading) || root.querySelector('input[type="checkbox"]')) kind = 'multiple';
    else if (/判断/.test(heading)) kind = 'truefalse';
    else if (/填空/.test(heading)) kind = 'fill';
    else if (/简答|论述|名词解释/.test(heading)) kind = 'essay';
    else if (/单选/.test(heading) || options.length > 0) kind = 'single';
    if (kind === 'fill' || kind === 'essay') { choices = []; options = []; }
    const unsupported = !!title.querySelector('img, canvas, svg, math, .MathJax, .katex, mjx-container') ||
      choices.some(el => !!el.querySelector('img, canvas, svg, math, .MathJax, .katex, mjx-container')) ||
      options.some(o => !o.text) || options.length > 26 ||
      (!options.length && !fields.length) || (options.length > 0 && new Set(options.map(o => o.text)).size !== options.length);
    const blankCount = fields.length;
    const signature = JSON.stringify({ stem, kind, options, blankCount, unsupported });
    const id = uid(root);
    return { question: { id: frameID + ':' + id, frameID, signature, stem, kind, options, blankCount,
        unsupported, context: /exam|考试|试卷/i.test(location.pathname + ' ' + document.title) ? '考试' : '作业 / 测验' },
      root, choices, fields };
  }

  function questions() {
    const roots = [...document.querySelectorAll(qSelector)].filter(visible);
    const parsed = roots.map(parseQuestion).filter(Boolean);
    return parsed.filter(item => !parsed.some(other => other !== item && item.root.contains(other.root))).slice(0, 200);
  }

  function actionCandidates(pattern) {
    return [...document.querySelectorAll('button, a, input[type="button"], input[type="submit"], [role="button"], .nextBtn')]
      .filter(el => visible(el) && !el.disabled && el.getAttribute('aria-disabled') !== 'true' &&
        !el.classList.contains('disabled') && pattern.test(clean(el.value || el.innerText || el.getAttribute('title'))));
  }
  const nextQuestions = () => actionCandidates(/^(?:下一题|下一页|下一题\s*[>›»→])$/);
  const nextChapters = () => {
    const known = [...document.querySelectorAll('#prevNextFocusNext, .nextChapter, [data-hori-next-chapter]')].filter(visible);
    return [...new Set([...known, ...actionCandidates(/^(?:下一节|下一章|下一章节)$/)])];
  };
  const submitButtons = () => actionCandidates(/^(?:交卷|提交|提交作业|提交试卷|确认交卷)$/);
  const allVideos = () => [...document.querySelectorAll('video')].filter(visible);

  function snapshot() {
    for (const [id, node] of nodes) if (!node.isConnected) nodes.delete(id);
    const markers = [...document.querySelectorAll('.ans-job-icon, [data-hori-complete]')].filter(visible);
    const completion = markers.length > 0 && markers.every(el => el.classList.contains('ans-job-finished') ||
      el.parentElement?.classList.contains('ans-job-finished') || el.getAttribute('data-hori-complete') === 'true')
      ? '页面全部任务标记显示完成' : '';
    return { frameID, title: clean(document.title).slice(0, 200), questions: questions().map(q => q.question),
      videos: allVideos().map(v => ({ id: uid(v), current: Number.isFinite(v.currentTime) ? v.currentTime : 0,
        duration: Number.isFinite(v.duration) ? v.duration : 0, paused: v.paused, ended: v.ended })),
      blocked: blocker(), nextQuestion: nextQuestions().length === 1, nextChapter: nextChapters().length === 1,
      submitCount: submitButtons().length, completion };
  }

  function isSelected(el) {
    const input = el.matches('input') ? el : el.querySelector('input[type="radio"], input[type="checkbox"]');
    if (input) return !!input.checked;
    if (el.matches('.answer_p') && el.parentElement) el = el.parentElement;
    if (el.getAttribute('aria-checked') != null) return el.getAttribute('aria-checked') === 'true';
    if (el.querySelector('[aria-checked="true"]')) return true;
    return el.matches('.selected, .checked, .active, .check_answer, .check_answer_dx, .check_answer_duo') ||
      !!el.querySelector('.check_answer, .check_answer_dx, .check_answer_duo, .selected, .checked');
  }

  async function fill(command) {
    if (blocker()) throw new Error(blocker());
    const current = questions().find(q => q.question.id === command.id);
    if (!current || current.question.signature !== command.signature) throw new Error('题目或选项已经变化，已阻止填写。');
    if (current.question.unsupported || current.question.kind === 'unknown') throw new Error('题目包含无法可靠识别的内容。');
    const chosen = command.selectedOptionIDs || [];
    const texts = command.textAnswers || [];
    if (current.question.options.length) {
      const known = new Set(current.question.options.map(o => o.id));
      if (!chosen.length || new Set(chosen).size !== chosen.length || chosen.some(id => !known.has(id)) ||
          (current.question.kind !== 'multiple' && chosen.length !== 1)) throw new Error('选项答案不符合题型。');
      // Never replace a student's existing choice silently.
      const existing = current.choices.map(isSelected);
      const desired = current.question.options.map(o => chosen.includes(o.id));
      if (existing.some(Boolean) && existing.some((value, index) => value !== desired[index]))
        throw new Error('页面已有不同的答案，请先在网页中自行清空或核对。');
      for (let index = 0; index < desired.length; index++) {
        if (!desired[index] || isSelected(current.choices[index])) continue;
        const el = current.choices[index];
        const input = el.querySelector('input[type="radio"], input[type="checkbox"]');
        const target = input && visible(input) ? input : (el.querySelector('[role="radio"], [role="checkbox"], .after') || el);
        target.click();
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (current.choices.some((el, index) => isSelected(el) !== desired[index]))
        throw new Error('已尝试填写，但无法读回确认选择状态。请在网页中核对。');
    } else {
      if (texts.length !== current.fields.length || texts.some(value => !clean(value))) throw new Error('文本答案数量不匹配。');
      for (let index = 0; index < texts.length; index++) {
        const el = current.fields[index];
        const old = clean(el.isContentEditable ? el.innerText : el.value);
        if (old && old !== clean(texts[index])) throw new Error('输入框已有不同答案，请先人工核对。');
      }
      current.fields.forEach((el, index) => {
        el.focus();
        if (el.isContentEditable) el.textContent = texts[index];
        else {
          const prototype = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, texts[index]);
        }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true })); el.blur();
      });
      if (current.fields.some((el, index) => clean(el.isContentEditable ? el.innerText : el.value) !== clean(texts[index])))
        throw new Error('无法读回确认文本答案。');
    }
    return { ok: true, message: '已填写并读回确认，尚未提交。' };
  }

  async function dispatch(command) {
    if (!command || typeof command.action !== 'string') throw new Error('操作无效。');
    if (command.action === 'scan') return snapshot();
    if (command.action === 'fill') return await fill(command);
    if (command.action === 'pauseVideo') { allVideos().forEach(v => v.pause()); return { ok: true }; }
    if (blocker()) throw new Error(blocker());
    if (command.action === 'playVideo') {
      const videos = allVideos();
      if (videos.some(v => !v.paused && !v.ended)) return { ok: true, message: '视频正在播放。' };
      const video = videos.find(v => !v.ended);
      if (!video) throw new Error('当前页没有尚未播放完的视频。');
      // Only normal media playback. No seeking, progress requests, blur overrides, or rate changes.
      await video.play(); return { ok: true, message: '已开始实际播放视频。' };
    }
    let buttons = [];
    if (command.action === 'nextQuestion') buttons = nextQuestions();
    if (command.action === 'nextChapter') {
      if (allVideos().some(v => !v.ended)) throw new Error('当前页视频尚未播放结束。');
      buttons = nextChapters();
    }
    if (command.action === 'submit') buttons = submitButtons();
    if (buttons.length !== 1) throw new Error('无法唯一识别操作按钮，请在网页中操作。');
    buttons[0].scrollIntoView({ block: 'center' }); buttons[0].click();
    return { ok: true, message: command.action === 'submit' ? '已点击提交，请核对网站回执或后续确认。' : '已点击下一项。' };
  }

  globalThis.HoriStudy = Object.freeze({ snapshot, dispatch });
  function report() {
    try { window.webkit?.messageHandlers?.horiStudy?.postMessage(snapshot()); } catch (_) { /* Navigation may destroy a frame. */ }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', report, { once: true });
  else report();
  setInterval(report, 2000);
})();
