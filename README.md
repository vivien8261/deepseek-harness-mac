# DeepSeek Harness for macOS

macOS 桌面壳：后台启动 dsh 本地 Web 服务，用内嵌浏览器展示官方 Web UI，退出时一并结束服务。

**推荐使用 Electron（Chromium）壳**（`build-electron.sh`）。WebKit/WKWebView 壳存在前端兼容性问题：harness 前端对助手流的对象语义校验在 WebKit 下崩溃（`Assistant stream raw chunk must be a lossless JSON object`，正文空白、点击会话无响应），Chrome 与 Electron 共用引擎、不受影响。WKWebView（AppKit）壳保留在 `build.sh` 中以便对照。

## 项目结构

- `macos/DSH/` — Swift 桌面壳源码（WKWebView 版）
  - `Main.swift` / `AppDelegate.swift` — App 入口与菜单（含 View ▸ Reload，⌘R）
  - `MainWindowController.swift` — 主窗口（1280×800，最小 900×600）与启动/关闭流程
  - `ServerSupervisor.swift` — 服务生命周期：选端口、spawn、就绪检测、退出清理
  - `NodeEnvironment.swift` — 内置运行时的定位与启动参数/环境
  - `ProcessGroup.swift` — `posix_spawn` 启动，进程组及递归子进程的终止
  - `DSHWebView.swift` — `WKWebView` 封装与导航策略
  - `LoadingOverlay.swift` — 启动覆盖层（状态、日志、重试按钮）
  - `LaunchLog.swift` — 诊断日志
  - `Info.plist` / `DSH.entitlements` / `Assets/`（应用图标）
- `macos/shell-electron/` — Electron（Chromium）壳：`main.js` 负责 spawn 内置 dsh web、等待 `dsh web:` 就绪行、打开浏览器窗口、退出时结束服务
- `macos/upgrade.sh` — 一键升级：拉取上游最新 `dsh-v*` tag、更新 submodule、重建并安装 App
- `macos/scripts/` — 构建脚本
  - `build-dsh.sh` — 从 submodule 源码构建 dsh（带缓存）
  - `stage-runtime.sh` — 打包独立运行时：dsh 生产闭包 + 官方 Node 24（带缓存）
  - `materialize-runtime.mjs` — 展开 deploy 树的 symlink、补齐缺失的 workspace 包、裁剪构建产物
  - `patch-wkwebview-auth.mjs` — 让 WKWebView 能连上 0.1.3 的实时 WebSocket（SameSite=Lax + 启动 token）
  - `verify-runtime-auth.sh` — 校验运行时已含 WebSocket 鉴权补丁，缺失时构建大声失败
  - `make-icon.sh` / `MakeIcon.swift` — 由 `whale-source.png` 生成 `AppIcon.icns`
- `deepseek-harness/` — git submodule（浅克隆，钉在上游 `dsh-v*` 发布 tag；用 `macos/upgrade.sh` 升级）
- `dist/` — 构建产物（`.app`、独立运行时、缓存标记），已 gitignore
- `.cache/` — 构建缓存（corepack pnpm shim、Node 官方 tarball），已 gitignore

## 前置条件

**构建机**

- macOS 13+
- Xcode Command Line Tools（`swiftc`、`xcrun`、`iconutil`）
- [Node.js](https://nodejs.org/) 22.19+ 或 24+（上游 engines 为 `^22.19.0 || >=24.0.0`；构建脚本优先使用 `/opt/homebrew/opt/node@24` 或 `/usr/local/opt/node@24`）
- git（submodule 需要）
- pnpm：由 `corepack` 按上游 `packageManager`（pnpm@11.7.0）自动提供；corepack 不可用时需自备 pnpm ≥ 11

**运行机**

- 只需已安装的 `/Applications/DeepSeek Harness.app`（内置 Node 与 dsh）

## 构建

**Electron（Chromium）壳 —— 推荐：**

```sh
chmod +x macos/build-electron.sh
./macos/build-electron.sh            # 构建并安装到 /Applications
./macos/build-electron.sh --dist-only  # 只产出 dist/DeepSeek Harness.app
```

首次构建会下载 Electron 官方 zip（缓存在 `.cache/electron/`，之后离线复用）。产物与 WKWebView 版同名（`dist/DeepSeek Harness.app`），可整体替换 `/Applications` 中的旧版；Bundle id 相同（`ai.deepseek.dsh.macos`）。

**WKWebView（AppKit）壳 —— 保留用于对照：**

```sh
chmod +x macos/build.sh macos/upgrade.sh macos/scripts/*.sh
./macos/build.sh
./macos/build.sh --dist-only
```

`build.sh` 与 `build-electron.sh` 共用同一套 dsh 运行时流水线：

1. 初始化 submodule（缺失时 `git submodule update --init --depth 1`）
2. `build-dsh.sh`：按上游方式从源码构建 dsh（`pnpm install` + `pnpm run build`，client profile 为 `official`）
3. `stage-runtime.sh`：`pnpm deploy --prod` 生成 dsh 生产闭包、下载官方 Node 24 二进制，再解开 symlink、裁剪构建产物、应用 WebSocket 鉴权补丁，写入 `dist/runtime/` 与 `runtime.json`（含 `authPatch` 状态）
4. `verify-runtime-auth.sh`：确认运行时已含 `hasLaunchToken` + `SameSite=Lax`，缺失即构建失败，避免把坏运行时打进 App
5. 组装 `.app`（ad-hoc 签名）；默认安装到 `/Applications`（`--dist-only` 时跳过）

构建脚本会自动检测本机代理（`127.0.0.1:7890`）并用于依赖下载。构建结果安装到 `/Applications/DeepSeek Harness.app`；运行时不依赖源码仓库、git、pnpm 或 Homebrew Node，因此源码仓库在安装后可删除或移动。

## 运行行为（Electron 壳）

1. 选择 `3080–3180` 中第一个空闲端口（connect 探测，避免误判被占端口），spawn 包内 `node` 运行 `Contents/Resources/dsh/lib/bin.js web --host 127.0.0.1 --port <端口> --no-open`，工作目录固定为 `$HOME`。
2. 就绪检测：解析服务输出的 `dsh web: <url>` 就绪行（已去掉 ANSI 转义）后再打开带启动 token 的地址；不能用裸 `/` 探测结果打开页面，否则 0.1.3 的实时输出通道会连不上。
3. 页面在内置 Chromium 窗口中加载；指向本地 dsh 服务的链接保持在窗口内，外部链接交给系统默认浏览器打开。
4. 菜单：View ▸ Reload / Force Reload / DevTools；Help ▸ 打开日志文件（`~/Library/Logs/DeepSeekHarness.log`）。
5. 退出时结束 dsh 子进程（SIGTERM，5 秒后 SIGKILL）；App 只清理自身记录的孤儿 dsh web（`~/.dsh/.dsh-web-macos.json`），不影响终端中手动运行的 `dsh web`。

## 运行行为（WKWebView 壳）

1. 窗口立即出现，覆盖层显示启动日志（内置 dsh 版本、commit、Node 版本、端口等）。
2. 选择 `3080–3180` 中第一个空闲端口，spawn 包内 `node` 运行 `Contents/Resources/dsh/lib/bin.js web --host 127.0.0.1 --port <端口> --no-open`，工作目录固定为 `$HOME`（Web UI 中仍需手动选择 workspace）。
3. 就绪检测：解析服务输出的 `dsh web: <url>` 就绪行（已去掉 ANSI 转义）后再打开带启动 token 的地址；不能用裸 `/` 探测结果打开页面，否则 0.1.3 的实时输出通道会连不上。
4. 页面在 App 内的 `WKWebView` 中加载；指向本地 dsh 服务的链接保持在 App 内，外部链接交给系统默认浏览器打开。
5. 每次启动前 WKWebView 会清空本机站点数据（cookie、localStorage、IndexedDB、缓存）再加载 token 地址：避免把上一次运行遗留的前端状态带入会话（旧状态会让会话流在启动时崩溃、正文空白），启动 token 会立即签发新 cookie。会话与模型数据都在服务端 `~/.dsh`，不受影响。
6. 窗口标题显示已报告的 dsh 版本；`View ▸ Reload`（⌘R）在服务就绪后重载页面，未就绪时重试启动。
7. 退出时对进程组及其全部子进程发送 `SIGTERM`，5 秒后仍未退出则 `SIGKILL`。

## 构建缓存

- dsh 编译标记：`dist/.dsh-build-state.json`（记录 submodule commit、node、pnpm、client profile、产物路径）
- 独立运行时标记：`dist/runtime/runtime.json`（记录 commit、node、版本、arch、recipe、`authPatch`）
- 命中条件：标记中的字段与当前环境一致，且对应产物存在；任一变化（如升级 submodule tag、更换 Node 版本）都会触发重建
- 删除对应标记文件可强制重建

## 升级 dsh 版本

一键升级（查询上游最新 `dsh-v*` tag → 更新 submodule → 提交 → 重建并安装到 `/Applications`）。默认重建 **Electron（Chromium）壳**：

```sh
./macos/upgrade.sh
```

常用选项：

```sh
./macos/upgrade.sh --check          # 只对比当前与最新，有更新时退出码 2
./macos/upgrade.sh --list           # 列出上游 dsh-v* tag
./macos/upgrade.sh --tag dsh-v0.1.1-rc.2   # 固定到指定 tag（可降级）
./macos/upgrade.sh --shell chromium # 默认：构建 Electron（Chromium）壳（build-electron.sh）
./macos/upgrade.sh --shell appkit    # 构建 WKWebView（AppKit）壳（build.sh）
./macos/upgrade.sh --no-build       # 只更新 submodule，不构建
./macos/upgrade.sh --no-commit      # 更新后不提交
./macos/upgrade.sh --force          # 已是目标 tag 也强制重建
```

脚本只认 `dsh-v*` 发布 tag（忽略 `vendor-*` / `python-*` / `landlock-run-*`）。已是最新时直接退出；tag 变化会让构建缓存失效并触发重建。

## 数据与日志

- 会话与设置保存在 `~/.dsh`，不会随 App 覆盖而丢失
- 运行日志：`~/Library/Logs/DeepSeekHarness.log`（启动事件 + 包内 `console.log` / `console.error`）
- App 内查看：`View ▸ Server Logs`（⌘L）；用系统应用打开：`Help ▸ Open Log File`
- 启动日志会显示 `鉴权补丁：已应用/缺失`：缺失表示内置运行时已过期，重新运行 `macos/upgrade.sh` 或对应壳的构建脚本（`build-electron.sh`/`build.sh`）即可（否则页面能打开但实时输出收不到）
- 正常退出时 dsh 子进程一并结束；若 App 被强杀（如 `kill -9`），其 dsh web 进程可能残留并占用端口——新启动的 App 只清理自身记录的孤儿（`~/.dsh/.dsh-web-macos.json`），不会影响终端里手动运行的 `dsh web`
