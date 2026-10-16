# 开发与适配说明

## 实现

`App/` 是 SwiftUI 界面、WebKit 浏览器、调度器和钥匙串存储；`Core/` 包含答案规则、题库匹配和 OpenAI 请求；`Resources/chaoxing-adapter.js` 是原创页面适配器。

脚本在独立的 `WKContentWorld` 中对所有框架注入，只操作可信的学习通域名页面。各框架独立报告题目；原生层再次检查实际安全来源，使用目标 `WKFrameInfo` 发送操作，不通过页面 `postMessage` 接收任意执行指令。传给 JavaScript 的命令使用结构化参数，不拼接题目为代码。

只读 DOM 快照不包含页面 URL、表单密码、Cookie 或整页 HTML。填写命令需匹配同一框架、同一题目及完整内容签名，并读回结果。任何一次自动写入都不代表服务器已保存答案。

视频使用标准 HTMLMediaElement 的 `play`、`pause` 和状态读取，不调用进度日志接口、不改写 `currentTime`、`playbackRate`、失焦事件或可见性接口。自动切节依赖页面上的完成标记；不能识别的进度必须人工检查。

## 参考

- [OpenAI Responses API：联网检索](https://developers.openai.com/api/docs/guides/tools-web-search)：工具必选、检索引用及来源显示。
- [OpenAI：结构化输出](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)：严格 JSON Schema 与拒答处理。
- [超星公开教学帮助](https://special.chaoxing.com/special/screen/200069142)：课程、作业、考试与任务点的产品结构。
- [OCS 的公开超星适配文件](https://github.com/ocsjs/ocsjs/blob/4.0/packages/scripts/src/projects/cx.ts)：只用于核对现行常见 DOM 标记的名称，例如 `.questionLi`、`.mark_name`、`.answer_p`、`.TiMu` 和题型隐藏字段。未复制其执行逻辑，也未将其代码作为依赖。

公开的 DOM 标记只是适配线索，不能替代对用户实际学校页面的验证。代码不依赖平台的私有答题或成绩接口。

## 验证方法

`scripts/test.sh` 编译并运行原生测试程序。核心检查覆盖答案与来源验证、题库冲突、选项乱序、结构化响应和数据最小化；WebKit 检查在自建页面上实际点击与读回控件、阻止旧题写入以及验证暂停行为。

只有在登录真实学生账号、配置自己的 API 密钥并获得网站回执后，才能判断实际课程适配、答案质量、提交状态和观看进度。测试程序不包含真实账号，也不会访问真实试卷。
