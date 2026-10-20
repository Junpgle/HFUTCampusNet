# 校园 AI 助手（macOS）

> 实验性功能：通过合肥工业大学 AI-Flow 平台的正常聊天接口提供原生 macOS 流式问答。仅限本人已获授权的账号和智能体；不是官方 API SDK。

## 使用

1. 如果尚未使用 App 原有的 **统一身份认证同步** 登录学校 CAS，请先完成一次；如果已有有效 CAS 登录状态，不需要重复输入密码。
2. 打开菜单栏的 **校园 AI 助手…**。如果没有已建立的 AI 平台会话，App 会在内嵌窗口打开学校的 **信息门户** `https://one.hfut.edu.cn/`。
3. 按学校正常路径点击 **AI 应用中台（AI 应用广场） → 合工大辅导员**。该步骤必须由信息门户中的正式应用入口发起；不要直接从 CAS 登录页拼接 `service` 或复用其他服务的票据。内嵌 WebView 会接管门户打开新窗口的普通 HTTPS 校内链接。
4. 到达目标 AI 页面后，如果检测到 `AiFlow` 会话，App 会自动返回原生聊天界面；若仍停留在网页，可以点击 **返回聊天** 检查当前登录状态。
5. 智能体 ID、模型 ID 和会话 ID 可以在顶部配置。智能体与模型初始值仅来自一次抓包实例；留空的会话 ID 将尝试调用 `/chat/lastGroup`。如果返回结构不兼容，请从**自己**的已登录会话请求中取得 `groupId`。
6. 点击 **信息门户** 可以重新打开官方门户执行登录，而不是尝试直接把 CAS Cookie 冒充 AI 会话。出现「票根不符合目标服务」时，确认操作是从门户点击 AI 应用入口启动；若仍失败，应由平台维护方排查 CAS `service` 注册及回调匹配问题。
7. 可点击 **停止** 取消生成。聊天窗只显示最终回复和工具执行状态，不展示原始 SQL、思考数据或完整工具 JSON。

用户提供的最终页面示例：`https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=6aaW6aG1`。其中 `after` 的语义尚未从校方接口确认，**不能把这条最终 URL 视为能够替代从信息门户启动应用的登录入口**，也不要自行推断它是 CAS 票据。

## 技术结构

- 登录：独立 WKWebView 共享 App 现有 `WKWebsiteDataStore.default()`，复用已登录 CAS 的浏览器状态。若没有 AiFlow 会话，**显示** `one.hfut.edu.cn`，通过用户点击门户正式应用入口完成目标系统的服务认证。不会恢复/伪造 CAS 服务票据，也不会把 `CASTGC` 作为 `AiFlow` 使用。
- 请求：从 WebKit 的 cookie store 读取当前有效、属于 aipt.hfut.edu.cn 或 hfut.edu.cn 的 Cookie；使用内存中的临时 URLSession 向 https://aipt.hfut.edu.cn/api/af-api-agent/chat/send 发送 POST 请求。
- 请求体：text、groupId、aiLargeModelId、thinkingMode=balanced、debug=false、traceId。64 位整数以原始 JSON 数字传输，避免 JavaScript Number 精度问题。
- 响应：增量解析 text/event-stream；根据 type=text 追加文本；显示 tool_call_start/tool_call_result 的简化状态，不解析敏感工具输出。
- 会话：优先查询本人当前登录身份的最近会话，失败时由用户手动指定 groupId。模型和智能体 ID 存在 UserDefaults 中，聊天内容不另行持久化。App 不在配置文件中单独存储 Cookie，但 WebKit 默认网站数据存储可能按服务器设置持久保存学校登录 Cookie；可从学校网页退出账号或清理 App 网站数据。

## 风险与限制

- 这不是校方保证长期可用的公共稳定接口；平台路径、鉴权方式、groupId 获取方式、模型 ID 可能变化。
- 平台聊天工具可能获得高于普通用户直接数据库调用的权限；本客户端不会请求 /database/executeSql 或伪造用户身份。
- 不要将浏览器 Cookie、AiFlow 令牌、含有课程成绩的原始 SSE 日志或截图提交到公开仓库。
- 如果业务返回 401/403，尊重权限边界，重新网页登录或询问平台维护人员，不应绕过服务端鉴权。
- 应检查平台使用条款和学校数据使用规定；只查询本人有权访问的数据。
- 目前仅实现 macOS 原生客户端。Windows WPF 端尚未接入。
- CI 可以验证 macOS 编译；真实服务返回结构、session 获取、信息门户启动的 CAS 回跳与服务注册匹配，需要登录学校账户后在本机验证。

## 手动验证

1. 新开 App，若未检测到 AiFlow 会话，应显示学校信息门户而非直接访问 AI 深链；有有效 CAS 状态时应在门户内无需重复输入密码。
2. 从信息门户点击「AI 应用中台」再进入「合工大辅导员」，成功建立 AiFlow 会话后切换到原生聊天页。
3. 使用本人的智能体/模型/会话 ID，发送普通问题：应有 SSE 增量文本。
4. 请求自己的课程成绩：应由授权智能体工具查询，客户端只显示最终回答，不输出/保存工具原始 JSON。
5. 在回复过程中点击停止：应终止请求并恢复输入状态。
6. 尝试错误的组 ID、失效会话、离线网络：应显示错误状态且不会卡住 UI。
