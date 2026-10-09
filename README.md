# 📶 HFUTCampusNet

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2012%2B-blue.svg?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Language-Swift%20%7C%20Cocoa-orange.svg?style=flat-square" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/HFUT-合肥工业大学-red.svg?style=flat-square" alt="HFUT">
</p>

macOS 校园网桌面伴侣。告别频繁登录网页查看流量与频繁重登 Wi-Fi 的痛点，集 **Dr.COM 网关认证自动重连**、**自服务自适应流量监控** 与 **实时网络吞吐速率轮播** 于一身。

---

## 🌟 核心特性

- 🎯 **1:1 桌面悬浮小组件 (Desktop Widget)**：
  - 复刻自服务界面的经典 4 宫格卡片：**已用流量**、**可用流量**、**消费保护**、**账户余额**；
  - 原生 macOS 磨砂半透明毛玻璃质感，跟随系统明暗主题自适应切换；
  - 自由拖拽吸附至桌面任意角落，位置自动记忆。
- ⚡ **秒级感知与无感自动重连 (Auto Reconnect)**：
  - 接入 macOS 内核 `NWPathMonitor` 与休眠唤醒监听；
  - 遇到 Wi-Fi 信号重连、电脑开盖唤醒或网络掉线时，**秒级捕获并在后台无感完成认证上网**；
  - 重新连通后，系统右上角自动滑出横幅通知并伴随提示音。
- 🚀 **状态栏实时网速与流量轮播 (Speed Carousel)**：
  - 基于 Darwin 内核网络接口 `getifaddrs` 实时计算当前网络吞吐速率（下载 $\downarrow$ / 上传 $\uparrow$）；
  - 状态栏每 3.5 秒平滑轮播：`📶 97.5G | ¥7.28` $\longleftrightarrow$ `↓ 1.2M/s  ↑ 320K/s`；
  - 支持随心切换：智能轮播、仅流量余额、仅实时网速、并排紧凑显示。
- 🔑 **内置 Web 登录窗口**：
  - 告别手动抓包复制 Cookie 的烦琐步骤；内置原生 WebKit 登录窗口，网页端登录成功后自动拦截捕获会话并开启监控。
- 🍃 **超低功耗与零外部依赖**：
  - 纯 Swift / Cocoa 原生实现，不依赖任何第三方重量级框架；
  - 运行内存仅 10MB 左右，CPU 占用率低于 0.05%，极度省电。

---

## 📸 功能一览

| 模块 | 说明 |
| :--- | :--- |
| **顶部状态栏** | 常驻菜单栏，双屏交替轮播可用流量与实时网络上传/下载速率 |
| **桌面悬浮窗** | 半透明四宫格卡片，展示已用、可用、消费保护与账户余额，附带用量进度条与速率指示 |
| **网关自动重连** | 掉线秒级自动发起 `http://172.18.3.3/` 认证，开机/唤醒即连 |
| **通知栏提醒** | 掉线重新认证成功后，系统自动发送通知横幅提醒网络已恢复 |

---

## 🚀 下载与安装

### 方式一：直接下载开箱即用 (推荐)

前往 [Releases 页面](../../releases) 下载最新的 `HFUTCampusNet-macOS.zip`：
1. 解压后将 `HFUTCampusNet.app` 拖入 **「访达 -> 应用程序 (Applications)」**；
2. 双击打开即可使用。

> 💡 **其他人首次打开提示“未知开发者”或“无法验证”？**
> 因为开源软件未购买苹果 $99/年的商业公证证书，首次打开只需操作一次：
> - **方式 1**：在 macOS **「系统设置」→「隐私与安全性」**，滑到下方点击 **「仍要打开」** 即可！
> - **方式 2**：按住键盘 `Control` 键，鼠标右键点击应用选择 **「打开」**。
> - **永久有效**：macOS 本地应用**没有 7 天证书过期限制**，一次配置，永久正常使用！

> **设置开机自启动**：在 macOS **「系统设置」→「通用」→「登录项」** 中添加 `HFUTCampusNet` 即可随开机无感启动。

---

### 方式二：从源码本地构建

本项目无任何第三方依赖，本地只要有 Xcode Command Line Tools 即可直接编译：

```bash
# 1. 克隆代码仓库
git clone https://github.com/Junpgle/HFUTCampusNet.git
cd HFUTCampusNet

# 2. 一键本地构建
bash build.sh

# 3. 运行应用程序
open HFUTCampusNet.app
```

---

## 🛠️ 便携命令行工具 (CLI)

仓库中同时附带了一个独立轻量的 Python CLI 脚本 `cli/monitor.py`，支持终端直接查询或作为 **SwiftBar / xbar** 插件使用：

```bash
# 查看当前 172.18.3.3 在线认证状态（包含学号、IP、已用流量、余额、在线时长）
python3 cli/monitor.py --status

# 一键认证登录校园网
python3 cli/monitor.py --login

# 一键注销当前设备
python3 cli/monitor.py --logout

# 设置校园网账号与密码
python3 cli/monitor.py --set-portal <学号> <密码>

# 持续测速监控
python3 cli/monitor.py --speed
```

---

## ❓ 常见问题 (FAQ)

1. **为什么提示“未连接校园网络 Wi-Fi”？**
   - 校园网网关认证接口（`http://172.18.3.3/`）与自服务平台（`xywzz.hfut.edu.cn:8443`）属于校内局域网地址，请确保你的 Mac 已经连上学校 Wi-Fi、宿舍有线网，或者开启了学校官方 WebVPN / EasyConnect。
2. **账号密码存储安全吗？**
   - 账号密码仅保存在你本机的系统级偏好设置中，所有请求均直接且仅与校内官方网关服务器通信，绝不会向任何第三方服务器发送任何数据。
3. **会话过期了怎么办？**
   - 若自服务 Session 过期，点击菜单栏的 **“自服务授权 (xywzz:8443)...”**，在弹出的官方窗口中登录一次即可全自动更新凭证。

---

## 🤝 参与贡献

欢迎提交 Issue 反馈遇到的问题或提出改进想法！如果你改进了功能或优化了界面，欢迎提交 Pull Request。

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源。
