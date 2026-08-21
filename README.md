# DeepSeek Harness for macOS

macOS 桌面壳：启动后立即显示窗口，在后台启动 dsh（DeepSeek Harness）的本地 Web 服务，再用 `WKWebView` 加载官方 Web UI。App 退出时同时结束服务进程。

构建机从 git submodule（固定上游 tag `dsh-v0.1.1-rc.2`）编译 dsh，并把「dsh 生产闭包 + 官方 Node 24」一起打进 `.app`。安装到 `/Applications` 后，运行不再依赖源码仓库、git、pnpm 或本机 Homebrew Node。用户数据仍在 `~/.dsh`。

## 项目结构

- `macos/DSH/` — Swift 桌面壳源码
  - `Main.swift` / `AppDelegate.swift` — App 入口与菜单（含 View ▸ Reload，⌘R）
  - `MainWindowController.swift` — 主窗口（1280×800，最小 900×600）与启动/关闭流程
  - `ServerSupervisor.swift` — 服务生命周期：选端口、spawn、就绪检测、退出清理
  - `NodeEnvironment.swift` — 内置运行时的定位与启动参数/环境
  - `ProcessGroup.swift` — `posix_spawn` 启动，进程组及递归子进程的终止
  - `DSHWebView.swift` — `WKWebView` 封装与导航策略
  - `LoadingOverlay.swift` — 启动覆盖层（状态、日志、重试按钮）
  - `LaunchLog.swift` — 诊断日志
  - `Info.plist` / `DSH.entitlements` / `Assets/`（应用图标）
- `macos/scripts/` — 构建脚本
  - `build-dsh.sh` — 从 submodule 源码构建 dsh（带缓存）
  - `stage-runtime.sh` — 打包独立运行时：dsh 生产闭包 + 官方 Node 24（带缓存）
  - `materialize-runtime.mjs` — 展开 deploy 树的 symlink、补齐缺失的 workspace 包、裁剪构建产物
  - `make-icon.sh` / `MakeIcon.swift` — 由 `whale-source.png` 生成 `AppIcon.icns`
- `deepseek-harness/` — git submodule（浅克隆，固定 tag `dsh-v0.1.1-rc.2`）
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

```sh
chmod +x macos/build.sh macos/scripts/make-icon.sh macos/scripts/build-dsh.sh macos/scripts/stage-runtime.sh
./macos/build.sh
open "/Applications/DeepSeek Harness.app"
```

`macos/build.sh` 依次执行：

1. 初始化 submodule（缺失时 `git submodule update --init --depth 1`）
2. `build-dsh.sh`：按上游方式从源码构建 dsh（`pnpm install` + `pnpm run build`，client profile 为 `official`）
3. `stage-runtime.sh`：`pnpm deploy --prod` 生成 dsh 生产闭包、下载官方 Node 24 二进制，再解开 symlink 并裁剪构建产物，写入 `dist/runtime/`
4. 编译 Swift 壳，把 `dist/runtime/` 内容装入 `Contents/Resources/`，生成 `.app`（ad-hoc 签名），安装到 `/Applications`

构建脚本会自动检测本机代理（`127.0.0.1:7890`）并用于依赖下载。构建结果安装到 `/Applications/DeepSeek Harness.app`；运行时不依赖源码仓库、git、pnpm 或 Homebrew Node，因此源码仓库在安装后可删除或移动。

## 运行行为

1. 窗口立即出现，覆盖层显示启动日志（内置 dsh 版本、commit、Node 版本、端口等）。
2. 选择 `3080–3180` 中第一个空闲端口，spawn 包内 `node` 运行 `Contents/Resources/dsh/lib/bin.js web --host 127.0.0.1 --port <端口> --no-open`，工作目录固定为 `$HOME`（Web UI 中仍需手动选择 workspace）。
3. 就绪检测：解析服务输出的 `dsh web: <url>` 就绪行（已去掉 ANSI 转义），同时对端口做 HTTP 探测作为兜底；任一先命中即加载页面。
4. 页面在 App 内的 `WKWebView` 中加载；指向本地 dsh 服务的链接保持在 App 内，外部链接交给系统默认浏览器打开。
5. 窗口标题显示已报告的 dsh 版本；`View ▸ Reload`（⌘R）在服务就绪后重载页面，未就绪时重试启动。
6. 退出时对进程组及其全部子进程发送 `SIGTERM`，5 秒后仍未退出则 `SIGKILL`。

## 构建缓存

- dsh 编译标记：`dist/.dsh-build-state.json`（记录 submodule commit、node、pnpm、client profile、产物路径）
- 独立运行时标记：`dist/runtime/runtime.json`（记录 commit、node、版本、arch、recipe）
- 命中条件：标记中的字段与当前环境一致，且对应产物存在；任一变化（如升级 submodule tag、更换 Node 版本）都会触发重建
- 删除对应标记文件可强制重建

## 升级 dsh 版本

```sh
git -C deepseek-harness fetch --depth 1 origin tag <新tag>
git -C deepseek-harness checkout <新tag>
git add deepseek-harness && git commit -m "bump deepseek-harness to <新tag>"
./macos/build.sh
```

## 数据与日志

- 会话与设置保存在 `~/.dsh`，不会随 App 覆盖而丢失
- 启动诊断日志：`~/Library/Logs/DeepSeekHarness.log`
