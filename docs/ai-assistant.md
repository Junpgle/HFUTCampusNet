# 校园 AI 助手（macOS）

> 实验性功能：通过合肥工业大学 AI-Flow 平台的正常聊天接口提供原生 macOS 流式问答。仅限本人已获授权的账号和智能体；不是官方 API SDK。

## 使用

1. 先使用 App 原有的 **统一身份认证同步** 完成一次 CAS 登录（如果已经登录则无需重复操作）。
2. 构建并启动 App，在状态栏菜单选择 **校园 AI 助手…**。窗口会自动检查 App 现有 CAS Cookie，并通过 AI 平台首页为目标服务完成单点登录。
3. 出现 **「已复用 CAS 登录并建立 AI 会话」** 后，输入问题，按回车或点击 **发送**。上方的 **「重连 AI」** 用于会话过期后重新初始化。
4. 如果遇到「票根不符合目标服务」，那是 CAS 服务票据与注册服务地址不一致，客户端不会伪造或跨服务使用 ST。可先在 App 内重新执行统一认证；若仍出错，需要校方维护者核查 AI 平台 CAS Service 配置。
4. 上方可配置 **智能体 ID**、**模型 ID** 和 **会话 ID**。初始智能体和模型 ID 来源于一次已验证的请求示例，不代表所有账号都可用。更换智能体时需要同步使用它对应的 ID。
5. 如果会话 ID 留空，客户端会尝试请求 /chat/lastGroup；该接口的 businessType 在平台文档中未有完整说明，失败时需从你自己网页登录后的 /chat/send 请求复制 groupId 并填入。不要复制其他人的会话 ID。
6. 可点击 **停止** 取消生成；窗口内仅显示用户提问、智能体最终文本，以及简短的工具运行状态，不展示/保存 SQL 或内部思考内容。

## 技术结构

- 登录：独立 WKWebView，共享 App 现有 WKWebsiteDataStore.default()；自动使用现有有效 CAS Cookie。如果 WKWebsiteDataStore 缺少 TGC，但旧版统一登录在本机 SettingsManager 中保存过 TGC，则仅在 cas.hfut.edu.cn/cas 路径恢复它。再加载 AI 平台首页，由服务自行完成符合 CAS 规范的认证并设置自身 AiFlow Cookie。不会跨域发送 CAS TGC 或直接复用其他服务的 ST。
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
- CI 可以验证 macOS 编译；真实服务返回结构、session 获取、AI 首页回跳及 CAS service 配置，需要登录学校账户后在本机验证。

## 手动验证

1. 新开 App，不登录，发送一条问题：应提示网页登录。
2. 用本人的合法账号登录学校 AI 页面，返回原生聊天页。
3. 使用本人的智能体/模型/会话 ID，发送普通问题：应有 SSE 增量文本。
4. 请求自己的课程成绩：应由授权智能体工具查询，客户端只显示最终回答，不输出/保存工具原始 JSON。
5. 在回复过程中点击停止：应终止请求并恢复输入状态。
6. 尝试错误的组 ID、失效会话、离线网络：应显示错误状态且不会卡住 UI。
