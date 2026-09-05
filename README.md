# DeepSeek Harness for macOS

<div align="center">
  <img src="macos/DSH/Assets/AppIcon-1024.png" width="96" alt="DeepSeek Harness for macOS" />
</div>

[DeepSeek Harness](https://deepseek-harness.github.io/deepseek-harness/)（`dsh`）官方 Web UI 的 macOS 桌面版：像使用普通 Mac 应用一样完成 AI 编程任务，开箱即用。

## 这是什么

DeepSeek Harness（`dsh`）是 DeepSeek 开源的 Agent harness，基于 Cordis 的**一切皆插件**架构（上游仍处于 developer preview，行为可能变动）。官方 Web UI 提供完整的工作台体验：用自然语言布置任务，助手自主读取代码、运行命令、修改文件，并展示思考、过程与结果；会话与设置持久化在本地，随时可以接着上次的工作继续。

本项目把官方 Web UI 打包成 macOS 桌面应用，功能与原版完全一致，并跟随上游 `dsh-v*` 发布 tag 持续更新，适合希望以桌面应用方式使用 DeepSeek Harness 的 macOS 用户。

## 为什么做它

官方开箱方式 `npx @deepseek-ai/dsh web` 需要在终端里装 Node、跑命令、手动管理服务进程。本项目的目标是把同样的工作台收敛成一个普通 Mac 应用：

- **自带运行时**：dsh 与 Node 一并打包进 `.app`，运行机零依赖
- **即开即用**：双击启动即可使用，退出后自动收尾
- **数据不丢失**：会话与设置保存在 `~/.dsh`，升级或重装 App 均不受影响
- **一键升级**：跟随上游发布 tag 重建并安装，一条命令完成

## 功能一览

- **对话式编程**：用自然语言描述需求，助手自动读写代码、执行命令、验证结果，过程与结果全程可见
- **完整 Agent 能力**：文件系统、终端、LSP、网页搜索与抓取、子代理、计划模式、TODO 清单等开箱即用
- **会话持久化**：会话与设置保存在本地，随时继续未完的工作
- **插件化扩展**：一切皆插件，通过 `cordis.yml` 组合插件调整能力与行为
- **持续更新**：跟随上游 `dsh-v*` 发布 tag 构建，一条命令升级到最新版

## 快速开始

**构建机前置条件**

- macOS 13+，Xcode Command Line Tools（`swiftc`、`xcrun`、`iconutil`）
- [Node.js](https://nodejs.org/) 22.19+ 或 24+（脚本优先使用 `/opt/homebrew/opt/node@24` 或 `/usr/local/opt/node@24`）
- git（submodule 需要）；pnpm 由 `corepack` 按上游 `packageManager`（pnpm@11.7.0）自动提供

**构建并安装（一行命令）**

```sh
./macos/build-electron.sh            # 构建并安装到 /Applications
./macos/build-electron.sh --dist-only  # 只产出 dist/DeepSeek Harness.app，不安装
```

构建完成后，在启动台或 `/Applications` 找到 **DeepSeek Harness**，双击即可使用。运行机只需已安装的 App——源码仓库、git、pnpm、Homebrew Node 一律不需要，安装后可删除或移动。

如需 WKWebView 壳作对照：

```sh
./macos/build.sh
./macos/build.sh --dist-only
```

> **推荐 Electron（Chromium）壳**：harness 前端对助手流的对象语义校验在 WebKit 下会崩溃（`Assistant stream raw chunk must be a lossless JSON object`，正文空白、点击会话无响应），Chrome 与 Electron 共用引擎、不受影响；WKWebView（AppKit）壳保留用于对照。两壳产物同名同 Bundle ID（`ai.deepseek.dsh.macos`），可整体替换 `/Applications` 中的旧版。

## 使用体验

**启动**：窗口立即出现，覆盖层显示启动日志（内置 dsh 版本、commit、Node 版本、端口）。App 会在 `3080–3180` 中挑选第一个空闲端口（connect 探测，避免误判被占端口），spawn 包内 `node` 运行 dsh 的 `web` 命令，工作目录固定为 `$HOME`（Web UI 中需手动选择 workspace）。

**就绪**：解析服务输出的 `dsh web: <url>` 就绪行（已去 ANSI 转义）后再打开带启动 token 的地址。不能直接用 `/` 探测结果打开页面，否则 0.1.3 的实时输出通道会连不上。

**使用中**：指向本地 dsh 服务的链接保持在窗口内，外部链接交给系统默认浏览器打开；`View ▸ Reload`（⌘R）重载页面。Electron 壳菜单含 Reload / Force Reload / DevTools；WKWebView 壳提供 `View ▸ Server Logs`（⌘L）。`Help ▸ Open Log File` 用系统应用打开运行日志。

**退出**：向 dsh 子进程（及进程组全部子进程）发送 `SIGTERM`，5 秒后仍未退出则 `SIGKILL`。App 只清理自身记录的孤儿 dsh web（`~/.dsh/.dsh-web-macos.json`），不影响终端中手动运行的 `dsh web`。

**WKWebView 壳的差异**：每次启动前会清空本机站点数据（cookie、localStorage、IndexedDB、缓存）再加载 token 地址，避免把上一次运行遗留的前端状态带入会话——这也是 WebKit 版的历史崩溃根因之一。会话与模型数据都在服务端 `~/.dsh`，不受影响。

## 升级 dsh 版本

```sh
./macos/upgrade.sh        # 一键升级：查询最新 dsh-v* tag → 更新 submodule → 重建并安装
```

常用选项：

| 选项 | 说明 |
| --- | --- |
| `--check` | 只对比当前与最新，有更新时退出码 2 |
| `--list` | 列出上游 dsh-v* tag |
| `--tag dsh-v0.1.1-rc.2` | 固定到指定 tag（可降级） |
| `--shell chromium` | 默认：构建 Electron（Chromium）壳 |
| `--shell appkit` | 构建 WKWebView（AppKit）壳 |
| `--no-build` | 只更新 submodule，不构建 |
| `--no-commit` | 更新后不提交 |
| `--force` | 已是目标 tag 也强制重建 |

脚本只认 `dsh-v*` 发布 tag（忽略 `vendor-*` / `python-*` / `landlock-run-*`）。tag 变化会让构建缓存失效并触发重建。

## 数据与日志

- 会话与设置保存在 `~/.dsh`，不会随 App 覆盖而丢失
- 运行日志：`~/Library/Logs/DeepSeekHarness.log`
- 启动日志会显示 `鉴权补丁：已应用/缺失`：缺失表示内置运行时已过期，重新运行 `upgrade.sh` 或对应壳的构建脚本即可（否则页面能打开但实时输出收不到）
- 正常退出时 dsh 子进程一并结束；若 App 被强杀（如 `kill -9`），其 dsh web 进程可能残留并占用端口——新启动的 App 只清理自身记录的孤儿

## 构建流水线（开发者）

`build.sh` 与 `build-electron.sh` 共用同一套运行时流水线：

1. 初始化 submodule（缺失时 `git submodule update --init --depth 1`）
2. `build-dsh.sh`：按上游方式从源码构建 dsh（`pnpm install` + `pnpm run build`，client profile 为 `official`）
3. `stage-runtime.sh`：`pnpm deploy --prod` 生成生产闭包、下载官方 Node 24 二进制，解开 symlink、裁剪构建产物、应用 WebSocket 鉴权补丁，写入 `dist/runtime/` 与 `runtime.json`（含 `authPatch` 状态）
4. `verify-runtime-auth.sh`：确认运行时已含 `hasLaunchToken` + `SameSite=Lax`，缺失即构建失败，避免把坏运行时打进 App
5. 组装 `.app`（ad-hoc 签名）；默认安装到 `/Applications`（`--dist-only` 时跳过）

**构建缓存**由 `dist/.dsh-build-state.json`（submodule commit、node、pnpm、client profile、产物路径）与 `dist/runtime/runtime.json`（commit、node、版本、arch、recipe、`authPatch`）标记；字段与当前环境一致且产物存在时命中，任一变化（如升级 tag、更换 Node 版本）都会触发重建。删除对应标记文件可强制重建。

首次构建的依赖（Electron zip、Node tarball、dsh 编译产物）均有缓存，之后离线复用；构建脚本会自动检测本机代理（`127.0.0.1:7890`）用于依赖下载。

## 许可

[MIT](deepseek-harness/LICENSE)。上游 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 与其第三方依赖的许可见 `deepseek-harness/THIRD_PARTY_NOTICES.md`。
