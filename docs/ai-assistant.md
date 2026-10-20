# 校园 AI 助手（macOS）

> 实验性功能：通过合肥工业大学 AI-Flow 平台的正常聊天接口提供原生 macOS 流式问答。仅限本人已获授权的账号和智能体；不是官方 API SDK。

## 使用

1. 如果尚未使用 App 原有的 **统一身份认证同步** 登录学校 CAS，请先完成一次；如果已有有效 CAS 登录状态，不需要重复输入密码。
2. 打开菜单栏的 **校园 AI 助手…**。如果没有 AI 平台会话，App 会在内嵌窗口打开学校信息门户 `https://one.hfut.edu.cn/`。
3. 在信息门户中按学校正常路径进入 [AI 应用中台](https://aipt.hfut.edu.cn/index/agent)，再进入 [AI 应用广场](https://aipt.hfut.edu.cn/index?forceIndex=1)，最后打开 [合工大 AI 辅导员](https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=6aaW6aG1)。让门户和 AI 平台发起原有 SSO 跳转；不要手工拼接 CAS `service`、复制或复用 Service Ticket。
4. 到达目标智能体页后，App 会检查是否出现 AI 平台 Cookie，但这只表示发现会话 Cookie，不能证明服务端仍接受它。发送消息时由 `/chat/send` 的响应确认有效性；401/403 会提示重新从信息门户进入。
5. 智能体 ID、模型 ID 和会话 ID 可在顶部配置。留空会话 ID 时，App 会尝试调用 `/chat/lastGroup`；其中 `businessType=1` 仍是待实测候选。若平台未返回该智能体的可用会话，可先在网页登录中打开目标对话，或填写自己已知的会话 ID。
6. **复制脱敏轨迹**只复制导航事件、host、已脱敏 path 和 query 参数名，不包含参数值、Cookie、ST、账号信息或请求正文。若认证仍失败，可把这段轨迹用于定位跳转链；不要提供密码或真实票据。
7. 可点击 **停止** 取消生成。聊天窗只显示最终回复和简化工具状态，不展示内部思考、SQL、原始工具输出或服务端错误详情。

用户提供的最终页面示例为 `https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=6aaW6aG1`。其中 `after` 的语义尚未从校方接口确认，不将其视作 CAS 凭证或脱离信息门户使用的认证链接。

## 技术结构

- 登录：独立 WKWebView 共享 App 现有 `WKWebsiteDataStore.default()`。弹窗也使用默认网站数据存储。内存中的导航轨迹只保存事件、host、脱敏 path 和 query 参数名；不记录参数值。API Cookie 按目标 host、路径和有效期筛选，并排除 `CASTGC`/`TGC`。不会构造或复用 CAS Service Ticket。
- 请求：使用不自动附加 Cookie 的临时 URLSession，只发送 WebKit 中符合 AI API 域名/路径范围的 Cookie，并按已观察到的请求在 `aiflow` Header 中带当前 `AiFlow` Cookie 值。
- 请求体：`text`、字符串形式的十进制 `groupId` 与 `aiLargeModelId`、`thinkingMode=balanced`、`debug=false`、`traceId`。使用 JSON 编码保留 64 位 ID 精度。
- 响应：按 SSE 帧解析拆分到达的数据，支持 LF/CRLF、分片中文、结束帧和错误帧；没有 `is_end` 的断连会按未完成处理。只显示文本和简化工具状态，不解析或保留内部思考、SQL 或工具正文。
- 会话：尝试通过 `/chat/lastGroup` 获取最近会话，校验返回状态、ID 格式及可用时的智能体 ID。`businessType=1` 仍待真实账号抓包确认。智能体/模型 ID 存在 UserDefaults 中；聊天内容不另行持久化。WebKit 默认网站数据存储可能按服务器设置持久保存学校登录 Cookie；可从学校网页退出账号或清理 App 网站数据。

## 自动化测试

运行脱敏协议测试：

```bash
bash Tests/run-campus-ai-tests.sh
```

测试覆盖 64 位 ID 编码与解析、Cookie 域名/路径/有效期筛选和 CAS Cookie 排除、导航轨迹脱敏、SSE 分片中文、CRLF、多行 data、结束/错误/超限处理。测试 fixture 仅含合成内容。

## 风险与限制

- 这不是校方保证长期可用的公共稳定接口；平台路径、鉴权方式、groupId 获取方式、模型 ID 可能变化。
- 平台聊天工具可能获得高于普通用户直接数据库调用的权限；本客户端不会请求 /database/executeSql 或伪造用户身份。
- 不要将浏览器 Cookie、AiFlow 令牌、含有课程成绩的原始 SSE 日志或截图提交到公开仓库。
- 如果业务返回 401/403，尊重权限边界，重新网页登录或询问平台维护人员，不应绕过服务端鉴权。
- 应检查平台使用条款和学校数据使用规定；只查询本人有权访问的数据。
- 目前仅实现 macOS 原生客户端。Windows WPF 端尚未接入。
- CI 可以验证 macOS 编译；真实服务返回结构、session 获取、信息门户启动的 CAS 回跳与服务注册匹配，需要登录学校账户后在本机验证。

## 手动验证

1. 新开 App，若未发现 AiFlow Cookie，应显示学校信息门户。请在内嵌窗口亲自登录（需要时），随后沿门户 → AI 应用中台 → AI 应用广场 → 合工大 AI 辅导员的路径操作。
2. 确认页面最终到达目标智能体且不出现 CAS `ST 不符合目标服务`。失败时点 **复制脱敏轨迹**；只分享复制出的脱敏记录。
3. 使用本人的智能体/模型/会话 ID，发送普通问题：应有 SSE 增量文本，并在 `is_end` 后正常结束。
4. 在回复过程中点击停止：应终止请求并恢复输入状态。测试失效会话、错误组 ID、离线网络时应显示可操作错误，不应把未结束的流报告为成功。
5. `lastGroup` 当前请求的 `businessType=1` 还需要用成功的目标智能体会话验证；若失败，复制请求路径和参数名/类型即可，不分享 Cookie、参数值或个人对话内容。
