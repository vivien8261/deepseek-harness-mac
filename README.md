# DeepSeek Harness for macOS

本地薄封装桌面壳：启动 App 后立刻显示窗口，后台运行官方 Web UI，再用 `WKWebView` 打开页面。关闭 App 时一并结束服务。

dsh 以 **git submodule** 形式随项目携带，固定在上游最新 tag `dsh-v0.1.1-rc.2`，从**源码构建**后运行（不再使用 `npx @deepseek-ai/dsh`）。构建产物带缓存标记，首次构建后启动直接复用，不会重复 install/build。

工作目录固定为 `$HOME`。Web UI 里仍需要手动选择 workspace。

## 前置条件

- macOS 13+
- Xcode Command Line Tools（`swiftc`、`iconutil`）
- [Node.js](https://nodejs.org/) 22.19+（或 24+；上游 engines 要求 `^22.19.0 || >=24.0.0`，Homebrew / nvm / fnm 均可）
- git（submodule 需要）
- pnpm：由 `corepack` 按上游 `packageManager`（pnpm@11.7.0）自动提供；corepack 不可用时需自备 pnpm ≥ 11

## 构建

```sh
chmod +x macos/build.sh macos/scripts/make-icon.sh macos/scripts/build-dsh.sh
./macos/build.sh
open "dist/DeepSeek Harness.app"
```

`macos/build.sh` 会先初始化 submodule（缺失时 `git submodule update --init`），再调用 `macos/scripts/build-dsh.sh` 构建 dsh（依赖安装 + `pnpm run build`），最后编译 Swift 壳。

## 行为

1. 窗口立即出现，显示详细启动日志（源码目录、commit、node 版本、缓存命中/构建过程、dsh 版本等）。
2. 启动时定位项目内 `deepseek-harness` submodule，直接运行其构建产物 `apps/cli/lib/bin.js`。产物缺失或源码/工具链变化时自动重新构建；**缓存命中时跳过构建**，秒级启动。默认端口 `3080`，占用则在 `3081–3180` 里另选。
3. 解析官方就绪行 `dsh web: http://127.0.0.1:<port>` 后再加载页面。
4. 退出时对进程组及其子进程发送 `SIGTERM`，5 秒后仍未退出则 `SIGKILL`。

## 构建缓存

- 标记文件：`dist/.dsh-build-state.json`（已被 .gitignore 忽略）。
- 命中条件：submodule HEAD commit、`node -v`、pnpm 调用方式均与标记一致，且产物 `apps/cli/lib/bin.js` 存在。
- 任一变化（如升级 submodule tag）都会触发一次完整重建；删除标记文件可强制重建。

## 升级 dsh 版本

```sh
git -C deepseek-harness fetch --depth 1 origin tag <新tag>
git -C deepseek-harness checkout <新tag>
git add deepseek-harness && git commit -m "bump deepseek-harness to <新tag>"
./macos/build.sh
```

启动诊断日志：`~/Library/Logs/DeepSeekHarness.log`。
