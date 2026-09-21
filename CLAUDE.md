# CrossTransfer

商业闭源的 P2P 文件传输工具（取件码模式），覆盖 Windows / macOS / Linux / iOS / Android。

## 先读

- `docs/PLAN.md`：完整规划 v7，包含所有已确认的设计决策、协议、依赖许可证边界、实施阶段与验证矩阵。**任何实施都以它为准**；改设计先改它。

## 当前状态（2026-09-21）

- 远程仓库 `github.com/kunkundi/crosstransfer`，主分支 `main`。
- **阶段 0 已完成**（服务端 + 特化版 MiniRTC + 数据路径改造），记录见 `docs/PHASE0_NOTES.md`：
  - `server/`：Go 信令 / 取件码 / 内嵌 TURN（pion/turn）/ WSS 中继 / healthz / metrics；`go test -race ./...` 全绿；Dockerfile + compose + `.env.example`。协议实现说明见 `docs/SIGNALING.md`。
  - `minirtc/`：已裁剪为数据专用（约 2.5 万行，源自 `kunkundi/minirtc` commit `a25a3b4`）。ICE 用 libjuice + miniupnpc，无 glib / libnice / 媒体依赖。C API 在 `minirtc/src/api/minirtc.h`（`MiniRtc*`）。macOS arm64、iOS arm64、Linux arm64 编译通过；Windows 尚未实测。
- **阶段 1 已完成**（`core/` + `ct_cli`），记录见 `docs/PHASE1_NOTES.md`，两端协议见 `docs/TRANSFER_PROTOCOL.md`：
  - 根 `xmake.lua`：`crosstransfer_core`（static）、`ct_cli`、`core_tests`（doctest，27 用例全绿）、可选 `crosstransfer_native`（shared，未验证）。
  - `core/include/crosstransfer/ct_api.h` 是唯一公开头（`CtCreate` … `CtVersion`，事件为 JSON 回调），阶段 2 的 ffigen 输入。
  - 端到端脚本在 `tools/`：`run_cli_e2e.sh`（P2P / TURN / 中继 / 丢包）、`run_cli_resume.sh`（kill -9 后续传）、`run_cli_open.sh`（open 模式双接收端）、`repeat_e2e.sh`。1 GiB 回环 156 s、峰值 RSS 35 MB。
- `app/` 尚未创建。
- 下一步：阶段 2（桌面 Flutter，macOS → Windows → Linux）。先安装 Flutter，再验证 `crosstransfer_native` 共享库与 ffigen。

## 硬约束（不要偏离）

- 闭源商业软件：不得引入 GPL / LGPL 依赖；ICE 层用 libjuice（MPL-2.0）+ miniupnpc（BSD-3），不用 libnice / glib。
- 核心逻辑全部新写，不从 `/Users/dijunkun/crossdesk` 复制代码；CrossDesk 只作参考。
- 服务端用 Go，信令协议见 `docs/PLAN.md` 第三部分。
- 文件数据走自研块协议（非可靠流 + 位图 SACK），控制消息走 KCP 可靠流。
- **命名**：函数一律大驼峰，包括 C API 导出（`CtCreate`、`MiniRtcSend`），不用蛇形；变量与文件名蛇形，枚举常量 `UPPER_SNAKE`。
- **提交信息**：Google/Angular 风格 `type(scope): 摘要`，正文中文，一次提交只做一件事。

## 参考路径

- CrossDesk（架构参考，只读）：`/Users/dijunkun/crossdesk`
- CrossDesk 设计文档库（只读）：`/Users/dijunkun/SourceCode/crossdesk-design`

## 环境

- 已有：xmake 3.1.0、Xcode、Go 1.25（`server/go.mod` 固定 `go 1.25`；升级 `golang.org/x/*` 时注意别把 go 指令拉到 1.26）。
- 未安装：Flutter / Dart（阶段 2 前安装）。

## 本地验证

```sh
tools/start_server.sh &                    # 构建并启动本地 ctserver（127.0.0.1:8080）
xmake f -m release -y && xmake build -y    # minirtc + core + ct_cli + core_tests
xmake run core_tests                       # 单元测试
tools/run_cli_e2e.sh p2p                   # 两进程端到端；turn --turn force / relay --relay force
MINIRTC_TEST_DROP_PERCENT=5 tools/run_cli_e2e.sh loss5 --turn off
tools/run_cli_resume.sh 200 3              # kill -9 接收端后凭 resume_token 续传
tools/run_cli_open.sh                      # open 模式两接收端并发
cd minirtc && examples/run_echo.sh p2p     # 仅 MiniRTC 层（见 minirtc/README.md）
```
