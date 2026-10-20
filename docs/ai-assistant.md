# 校园 AI 助手（macOS）

> 实验性功能：通过合肥工业大学 AI-Flow 平台的正常聊天接口提供原生 macOS 流式问答。仅限本人已获授权的账号和智能体；不是官方 API SDK。

## 使用

1. 如果尚未使用 App 原有的 **统一身份认证同步** 登录学校 CAS，请先完成一次；如果已有有效 CAS 登录状态，不需要重复输入密码。
2. 打开菜单栏的 **校园 AI 助手…**。如果没有 AI 平台会话，App 会在内嵌窗口打开学校信息门户 `https://one.hfut.edu.cn/`。
3. 在信息门户中按学校正常路径进入 [AI 应用中台](https://aipt.hfut.edu.cn/index/agent)，再进入 [AI 应用广场](https://aipt.hfut.edu.cn/index?forceIndex=1)，最后打开 [合工大 AI 辅导员](https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=6aaW6aG1)。让门户和 AI 平台发起原有 SSO 跳转；不要手工拼接 CAS `service`、复制或复用 Service Ticket。
4. 当门户跳转到可识别的 CAS 账号、密码和图片验证码表单时，会显示原生登录控件。账号和密码预填 App 现有的统一身份认证设置；提交时仍由当前 CAS 页面校验并跳转。验证码从该页面已加载的图片读取，刷新按钮点击该页面自己的刷新控件。若表单结构、验证码图片或刷新控件无法安全识别，选择 **使用网页登录**，继续在 CAS 页面操作。二维码、短信或其他登录方式始终可在网页登录中使用。
5. 到达目标智能体页后，App 会检查是否出现 AI 平台 Cookie，但这只表示发现会话 Cookie，不能证明服务端仍接受它。发送消息时由 `/chat/send` 的响应确认有效性；401/403 会提示重新从信息门户进入。
6. 到达目标智能体页后，App 会自动查询该智能体的最近会话并填入会话 ID；查询期间发送的消息会等会话就绪后继续发送。若历史响应明确返回空列表，App 会在用户首次发送时按网页观察到的流程调用 `POST /api/af-api-agent/chat/save`，读取并校验响应中的 `data.groupId`，再发送 `/chat/send`。不会预先创建没有首条消息的空会话；如果历史响应格式异常，则停止并提示重试，不会误判为空列表。
7. **复制脱敏轨迹**只复制导航事件、host、已脱敏 path 和 query 参数名，不包含参数值、Cookie、ST、账号信息或请求正文。若认证仍失败，可把这段轨迹用于定位跳转链；不要提供密码或真实票据。
8. 可点击 **停止** 取消生成。聊天窗只显示最终回复和简化工具状态，不展示内部思考、SQL、原始工具输出或服务端错误详情。

用户提供的最终页面示例为 `https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=6aaW6aG1`。其中 `after` 的语义尚未从校方接口确认，不将其视作 CAS 凭证或脱离信息门户使用的认证链接。

## 技术结构

- 登录：独立 WKWebView 共享 App 现有 `WKWebsiteDataStore.default()`。弹窗也使用默认网站数据存储。内存中的导航轨迹只保存事件、host、脱敏 path 和 query 参数名；不记录参数值。API Cookie 按目标 host、路径和有效期筛选，并排除 `CASTGC`/`TGC`。不会构造或复用 CAS Service Ticket。
- 原生 CAS 登录：只在 `https://cas.hfut.edu.cn/cas/login` 页面可见且可识别账号、密码、验证码和原始提交按钮时启用。验证码从当前页面已加载的图片经同源 canvas 读取；跨源画布、无匹配表单和不支持图片都会保留原网页。点击提交时回填页面原有控件并点击页面原有按钮，以保留隐藏字段、动态 service 和页面自己的会话状态。账号、密码复用 `SettingsManager` 当前已有字段，不另存一份；验证码只在当前面板内存中使用。
- 请求：使用不自动附加 Cookie 的临时 URLSession，只发送 WebKit 中符合 AI API 域名/路径范围的 Cookie，并按已观察到的请求在 `aiflow` Header 中带当前 `AiFlow` Cookie 值。
- 请求体：`text`、字符串形式的十进制 `groupId` 与 `aiLargeModelId`、`thinkingMode=balanced`、`debug=false`、`traceId`。使用 JSON 编码保留 64 位 ID 精度。
- 响应：按 SSE 帧解析拆分到达的数据，支持 LF/CRLF、分片中文、结束帧和错误帧；没有 `is_end` 的断连会按未完成处理。只显示文本和简化工具状态，不解析或保留内部思考、SQL 或工具正文。
- 会话：Edge 的首次发送抓包观察到 `POST /api/af-api-agent/chat/save`，请求字段/类型为 `groupId:null`、`text:string`、`businessId:string`、`businessType:number`、`type:number`、`sender:number`、`title:string`；授权检查的数值为 `businessType=4`、`type=2`、`sender=1`。响应结构为 `status:number`、`data:object`，其中 `groupId:string`、`chatId:string`、`msg:string`；该次业务 `status=1`。同一首次发送链路随后出现 `/chat/send`。据此推断 `chat/save` 响应中的 `data.groupId` 是后续发送要使用的会话 ID；App 仅在状态成功且 ID 格式有效时使用，不生成或跨服务复用 ID。网页抓包没有比较两个请求中的 ID 值，App 内端到端是否被服务端接受仍需本机验证。App 使用首条问题作为 `title`，这是根据字段用途作出的实现选择，尚未验证平台对标题的长度或格式限制。
- 历史会话：Edge 页面已观察到 `POST /api/af-api-agent/agent/getHistoryData`，请求体字段为 `pageNum:number`、`pageSize:number`、`type:number`、`topic:string`、`groupId:string`、`businessId:string`；本机网页请求确认使用 `pageNum=1`、`pageSize=20`、`type=2`、空 `topic/groupId`。响应结构含 `data.list`，记录含 `id`、`businessId` 和 `createTime`。App 按 `businessId` 匹配当前智能体并选择最近记录的 `id`，不保存或展示历史会话标题/正文。智能体/模型 ID 存在 UserDefaults 中；聊天内容不另行持久化。WebKit 默认网站数据存储可能按服务器设置持久保存学校登录 Cookie；可从学校网页退出账号或清理 App 网站数据。

## 自动化测试

运行脱敏协议测试：

```bash
bash Tests/run-campus-ai-tests.sh
```

测试覆盖 64 位 ID 编码与解析、Cookie 域名/路径/有效期筛选和 CAS Cookie 排除、导航轨迹脱敏、CAS 登录页 host/path 校验、凭据 JSON 编码、验证码数据格式/大小边界、SSE 分片中文、CRLF、多行 data、结束/错误/超限处理。测试 fixture 仅含合成内容。

## 风险与限制

- 这不是校方保证长期可用的公共稳定接口；平台路径、鉴权方式、groupId 获取方式、模型 ID 可能变化。`chat/save` 的字段与成功状态来自 Edge 的一次首次发送抓包，但原生 App 端的实时服务验证尚未完成；`title` 取首条问题、历史查询的请求体默认值以及“最近一条历史会话就是可继续发送的会话”仍需在 App 的真实 WebKit 登录状态下确认。
- 平台聊天工具可能获得高于普通用户直接数据库调用的权限；本客户端不会请求 /database/executeSql 或伪造用户身份。
- 不要将浏览器 Cookie、AiFlow 令牌、含有课程成绩的原始 SSE 日志或截图提交到公开仓库。
- 如果业务返回 401/403，尊重权限边界，重新网页登录或询问平台维护人员，不应绕过服务端鉴权。
- 应检查平台使用条款和学校数据使用规定；只查询本人有权访问的数据。
- 目前仅实现 macOS 原生客户端。Windows WPF 端尚未接入。
- CI 可以验证 macOS 编译；真实服务返回结构、session 获取、信息门户启动的 CAS 回跳与服务注册匹配，需要登录学校账户后在本机验证。

## 手动验证

1. 新开 App，若未发现 AiFlow Cookie，应显示学校信息门户。请在内嵌窗口亲自登录（需要时），随后沿门户 → AI 应用中台 → AI 应用广场 → 合工大 AI 辅导员的路径操作。
2. 在 CAS 账号密码登录页确认原生面板可以填充设置中保存的账号和密码，图片验证码与网页显示一致。手动刷新两次，确认旧验证码立即清除并展示新验证码；若面板检测失败，切换回网页并完成登录。
3. 使用原生面板提交正确验证码，确认 CAS 页面完成校验并沿门户的原始回跳到达目标智能体。另用错误验证码确认错误仍由 CAS 页面显示且可重新刷新；如出现 `ST 不符合目标服务`，用 **复制脱敏轨迹** 提供脱敏记录。
4. 沿门户正常打开辅导员页面后，等待历史查询完成。已有历史时确认会话 ID 自动填入；空历史时应提示首次发送会自动建会话。发送普通问题，确认 App 先创建会话，再通过 `/chat/send` 得到 SSE 增量文本，并在 `is_end` 后正常结束。需同时覆盖历史查询异常的情况，确认它不会误触发新会话创建。
5. 在回复过程中点击停止：应终止请求并恢复输入状态。测试失效会话、错误组 ID、离线网络时应显示可操作错误，不应把未结束的流报告为成功。
6. 自动准备会话若失败，只分享请求路径、方法/状态、字段名/类型和响应结构；不要分享 Cookie、参数值或个人对话内容。重点确认 history 请求体默认值是否被平台接受，以及返回的最新记录 ID 是否能用于 `/chat/send`。
