# DeepSeek Harness for macOS

本地薄封装桌面壳：启动 App 后立刻显示窗口，后台运行官方 Web UI，再用 `WKWebView` 打开页面。关闭 App 时一并结束服务。

构建机从 git submodule（固定上游 tag `dsh-v0.1.1-rc.2`）编译 dsh，再把 **生产闭包 + 官方 Node 24** 打进 `.app`。装到 `/Applications` 之后，运行不再依赖源码仓库、git、pnpm 或本机 Homebrew Node。用户数据仍在 `~/.dsh`。

工作目录固定为 `$HOME`。Web UI 里仍需要手动选择 workspace。

## 前置条件

**构建机**

- macOS 13+
- Xcode Command Line Tools（`swiftc`、`iconutil`）
- [Node.js](https://nodejs.org/) 22.19+（或 24+；上游 engines 要求 `^22.19.0 || >=24.0.0`）
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

`macos/build.sh` 会：

1. 初始化 submodule（缺失时 `git submodule update --init`）
2. 调用 `macos/scripts/build-dsh.sh` 在构建机编译 dsh
3. 调用 `macos/scripts/stage-runtime.sh`：`pnpm deploy --prod` 打出可拷贝闭包、解开 symlink、打入官方 Node 24
4. 编译 Swift 壳，把运行时放进 `Contents/Resources/`，安装到 `/Applications`

请从 `/Applications` 打开，不要从 `dist/` 运行。源码仓库可在安装后删除或搬家，不影响已安装的 App。

## 行为

1. 窗口立即出现，显示启动日志（内置 dsh 版本、commit、Node 版本、端口等）。
2. 直接 spawn 包内 `node` 运行 `Contents/Resources/dsh/lib/bin.js web --no-open`。默认端口 `3080`，占用则在 `3081–3180` 里另选。只在本 App 的 `WKWebView` 里打开，不再额外弹出系统浏览器。
3. 解析官方就绪行 `dsh web: http://127.0.0.1:<port>` 后再加载页面。
4. 退出时对进程组及其子进程发送 `SIGTERM`，5 秒后仍未退出则 `SIGKILL`。

## 构建缓存

- dsh 编译标记：`dist/.dsh-build-state.json`
- 独立运行时标记：`dist/runtime/runtime.json`
- 命中条件：submodule HEAD commit、`node -v` 与标记一致，且对应产物存在
- 任一变化（如升级 submodule tag）都会触发重建；删除对应标记文件可强制重建

## 升级 dsh 版本

```sh
git -C deepseek-harness fetch --depth 1 origin tag <新tag>
git -C deepseek-harness checkout <新tag>
git add deepseek-harness && git commit -m "bump deepseek-harness to <新tag>"
./macos/build.sh
```

会话与设置保留在 `~/.dsh`，不会随 App 覆盖而丢失。

启动诊断日志：`~/Library/Logs/DeepSeekHarness.log`。
