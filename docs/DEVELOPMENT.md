# 开发与适配说明

## 实现

`App/` 是 SwiftUI 界面、WebKit 浏览器、网页 AI 工作台、调度器和钥匙串存储；`Core/` 包含答案规则、题库匹配、供应商路由、API 传输及网页回答格式；两个 `Resources/*adapter.js` 是原创课程与聊天页面适配器。

`WebAIWorkspace` 为四家服务各建一个持久 WebKit 网站存储，复用生产浏览器控制器保留登录弹窗与回调。`ai-chat-adapter.js` 仅在所选服务的精确官方主机运行，在独立内容世界中写入输入区并点击正常发送按钮。它不读取 Cookie 或账号令牌。每题用随机请求标识关联新回答；不读取其他会话正文，不按文字静止时间单独判断生成结束。页面完成标记或回答操作区、完整 JSON、本次标识以及稳定读回都满足后才解析。已点击发送后不会自动重发；最多等待 240 秒后暂停。

作答与复核各开新会话，网站长期记忆仍可能相关。网页回答默认标为草稿，链接不当作已验证检索证据。用户可明确开启对双轮一致网页草稿的自动填写；歧义、不完整格式、非法选项和分歧仍不能通过。手动复制/导入采用同一题目标识，单轮回答需要人工核对。

Preview 4 针对实际 ChatGPT 登录版调整了富文本输入和完成状态识别。富文本提示先转义成纯文本 HTML，再通过浏览器编辑命令插入，避免 macOS 智能引号改变 JSON；写入后仍逐字核对，不接受改写的草稿。回答操作按钮可位于正文旁的单回答容器中，但不跨越其他回答或输入区。相同名称、控件类型和链接目标的新对话入口允许响应式重复；不同任务入口仍判为歧义。匿名清除确认会立即暂停；复核失败保留首轮未核验草稿。

可选 API 模式中，OpenAI 使用 Responses；DeepSeek、豆包及自定义兼容服务使用 Chat Completions。后者请求 JSON Object 或在自定义设置下省略格式参数，本机仍严格检查所有字段。复核请求不包含第一轮答案。全部所需密钥在开始前检查，API 传输使用无网站 Cookie 的临时会话和拒绝重定向的请求代理。OpenAI 原钥匙串项目保持兼容，自定义密钥用规范化 Base URL 的 SHA-256 作为账户标识的一部分。

脚本在独立的 `WKContentWorld` 中对所有框架注入，只操作可信的学习通域名页面。各框架独立报告题目；原生层再次检查实际安全来源，使用目标 `WKFrameInfo` 发送操作，不通过页面 `postMessage` 接收任意执行指令。传给 JavaScript 的命令使用结构化参数，不拼接题目为代码。

只读 DOM 快照不包含页面 URL、表单密码、Cookie 或整页 HTML。填写命令需匹配同一框架、同一题目及完整内容签名，并读回结果。任何一次自动写入都不代表服务器已保存答案。

视频使用标准 HTMLMediaElement 的 `play`、`pause` 和状态读取，不调用进度日志接口、不改写 `currentTime`、`playbackRate`、失焦事件或可见性接口。自动切节依赖页面上的完成标记；不能识别的进度必须人工检查。

登录弹窗通过 WebKit 提供的同一 `WKWebViewConfiguration` 创建真实页面，保留 POST、共享网站数据与 `window.opener`，支持先打开空白窗口再跳转的登录流程。活动标签页切换后，题目操作只允许定位当前页的框架。正常策略取消（`WebKitErrorDomain 102`）与取消请求（`NSURLErrorDomain -999`）不会产生登录失败弹窗；HTTPS 的真正错误仍会显示。脱敏诊断只记录主机及错误码，不记录完整回调链接。

Preview 5 为学校自定义落地页采用主页面 HTTPS 优先导航：旧 HTTP 跳转保留路径与参数，改用 HTTPS 请求，沿用系统证书校验，失败时不回退明文。自定义域名不会加入课程脚本可信列表，非超星域名的 HTTP 子框架仍被取消。

## 参考

- [OpenAI Responses API：联网检索](https://developers.openai.com/api/docs/guides/tools-web-search)：工具必选、检索引用及来源显示。
- [OpenAI：结构化输出](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)：严格 JSON Schema 与拒答处理。
- [DeepSeek：Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/) 与 [JSON Output](https://api-docs.deepseek.com/guides/json_mode/)：官方主机、JSON Object、完成原因与空响应处理。
- [火山方舟：结构化输出](https://docs.volcengine.com/docs/ark/structured-output-beta?lang=zh)：官方 Chat Completions、模型 ID、JSON Object 及 thinking 字段。
- [Apple：创建 WebKit 新页面](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:createwebviewwith:for:windowfeatures:))：使用回调提供的配置创建页面，由 WebKit 在新页面加载请求。
- [超星公开教学帮助](https://special.chaoxing.com/special/screen/200069142)：课程、作业、考试与任务点的产品结构。
- [OCS 的公开超星适配文件](https://github.com/ocsjs/ocsjs/blob/4.0/packages/scripts/src/projects/cx.ts)：只用于核对现行常见 DOM 标记的名称，例如 `.questionLi`、`.mark_name`、`.answer_p`、`.TiMu` 和题型隐藏字段。未复制其执行逻辑，也未将其代码作为依赖。

公开的 DOM 标记只是适配线索，不能替代对用户实际学校页面的验证。代码不依赖平台的私有答题或成绩接口。

## 验证方法

`scripts/test.sh` 编译并运行原生测试程序。核心检查覆盖答案与来源验证、题库冲突、选项乱序、结构化响应和数据最小化；WebKit 检查在自建页面上实际点击与读回控件、阻止旧题写入以及验证暂停行为。

`Tests/BrowserChecks.swift` 直接使用生产 `BrowserController` 和独立的、无学生账号的临时 WebKit 数据存储，通过测试专用资源处理器验证空白登录弹窗、POST 提交、父页面回调、共享 Cookie 存储、关窗返回与错误分类。测试协议许可仅通过原生测试程序注入；正式应用始终使用默认导航策略。

`Tests/ProviderChecks.swift` 使用模拟 URLProtocol 响应核对多供应商请求、凭据隔离、API 格式和网页回答校验；没有发送真实付费 API 请求。`Tests/WebChatChecks.swift` 在临时 WebKit 存储中加载自建聊天页，验证输入事件、一次发送、生成完成标志、旧回答隔离和生产 `WebAIWorkspace` 的两轮新会话。它不证明各家网站真实账号登录成功。

只有在登录真实学生账号、配置自己的 API 密钥并获得网站回执后，才能判断实际课程适配、答案质量、提交状态和观看进度。测试程序不包含真实账号，也不会访问真实试卷。
