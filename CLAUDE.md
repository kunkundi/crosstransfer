# CrossTransfer

商业闭源的 P2P 文件传输工具（取件码模式），覆盖 Windows / macOS / Linux / iOS / Android。

## 先读

- `docs/PLAN.md`：完整规划 v7，包含所有已确认的设计决策、协议、依赖许可证边界、实施阶段与验证矩阵。**任何实施都以它为准**；改设计先改它。

## 当前状态（2026-09-22）

- 远程仓库 `github.com/kunkundi/crosstransfer`，主分支 `main`。
- **阶段 0 已完成**（服务端 + 特化版 MiniRTC + 数据路径改造），记录见 `docs/PHASE0_NOTES.md`：
  - `server/`：Go 信令 / 取件码 / 内嵌 TURN（pion/turn）/ WSS 中继 / healthz / metrics；`go test -race ./...` 全绿；Dockerfile + compose + `.env.example`。协议实现说明见 `docs/SIGNALING.md`。
  - `minirtc/`：已裁剪为数据专用（约 2.5 万行，源自 `kunkundi/minirtc` commit `a25a3b4`）。ICE 用 libjuice + miniupnpc，无 glib / libnice / 媒体依赖。C API 在 `minirtc/src/api/minirtc.h`（`MiniRtc*`）。macOS arm64、iOS arm64、Linux arm64 编译通过；阶段 2 新增 Windows x64 / Linux x86_64 / macOS universal 构建与收发验收。
- **阶段 1 已完成**（`core/` + `ct_cli`），记录见 `docs/PHASE1_NOTES.md`，两端协议见 `docs/TRANSFER_PROTOCOL.md`：
  - 根 `xmake.lua`：`crosstransfer_core`（static）、`ct_cli`、`core_tests`（doctest，27 用例全绿）、可选 `crosstransfer_native`（shared，三桌面平台已验证）。
  - `core/include/crosstransfer/ct_api.h` 是唯一公开头（`CtCreate` … `CtVersion`，事件为 JSON 回调），阶段 2 的 ffigen 输入。
  - 端到端脚本在 `tools/`：`run_cli_e2e.sh`（P2P / TURN / 中继 / 丢包）、`run_cli_resume.sh`（kill -9 后续传）、`run_cli_open.sh`（open 模式双接收端）、`repeat_e2e.sh`。1 GiB 回环 156 s、峰值 RSS 35 MB。
- **阶段 2 工程验收已完成**（桌面 Flutter），记录见 `docs/PHASE2_NOTES.md`，构建操作见 `docs/DESKTOP_BUILD.md`：
  - `app/`：FFI / Riverpod、发送 / 接收 / 设置、中英文、拖放、二维码、scheme 链接、托盘、通知；补齐完整码自动接收、粘贴、冷/热启动转发和用户配置保留。
  - Windows x64、Linux x86_64、macOS universal 的 Actions 验收全绿：27 项 core tests / 299 断言、9 项 Flutter tests、15 个 FFI 导出、FFI ⇄ CLI 传输、Flutter release、安装后的首次/热启动链接收件。验收 run `35626385301`，代码提交 `2a1d761`，工作分支 `codex/phase2-desktop`。
  - 构建脚本 `tools/build_native.sh` / `tools/build_native.ps1`；打包脚本 `tools/package_macos.sh` / `tools/package_windows.ps1` / `tools/package_linux.sh`，产出 DMG / NSIS / deb 与 SHA-256。Windows 原生依赖统一动态 CRT，安装器携带运行库；Linux 自动计算 ELF 依赖。
  - macOS 最低 12.0、不启用 App Sandbox；当前 DMG 为 `local-test`。正式 Developer ID 签名/公证流程已提供，尚无发布证书；真实 Windows/Linux 桌面的托盘、通知与安装器交互外观仍需人工验收。
- **阶段 3 iOS 主要实现与本机验收已完成**，记录见 `docs/PHASE3_NOTES.md`，操作见 `docs/IOS_BUILD.md`：
  - iOS 15.0+，device arm64 / simulator arm64+x86_64 静态 XCFramework、分享扩展、扫码、Documents/Received、系统分享/导出、后台任务、手机布局。
  - 本机未签名 release / simulator 构建、15 项 ABI 符号检查、13 项 Dart 测试、4 项 XCTest（运行时 FFI、P2P、强制中继、失败重连）通过；CLI ⇄ iOS 实际收发校验通过，系统 Files 分享扩展已验收。
  - 修复心跳/重连条件变量锁不一致与 endpoint 生命周期问题；桌面 core 回归扩充至 28 用例 / 305 断言。
  - 正式 Bundle ID/Team/域名仍待确定，签名真机、相机实扫、后台系统到期与 Universal Link 部署验收未完成；iOS Actions `35634079792` 已全部通过。
- **阶段 4 Android 主要实现与本机自动化验收已完成**，见 `docs/PHASE4_NOTES.md`、`docs/ANDROID_BUILD.md`：
  - NDK 28.2 三 ABI、15 项 FFI 导出、16 KB 对齐；Application 引擎、前台服务、SAF 导入/导出、系统分享、scheme 与 App Link 配置。
  - 本机 2 项运行时 FFI、2 项 SAF/分享仪器测试、CLI 冷/热链接及后台接收通过；三 ABI Release 测试 APK 与 24 个原生库打包检查通过。
  - 原生三架构 Actions `35636445939` 全绿；完整 APK/模拟器 CI 待记录结果。正式签名、App Link、真机和 16 KB 系统运行验收待补。
- **阶段 5 加固进行中**，见 `docs/PHASE5_NOTES.md`：WSS SAN 身份验证、OpenSSL 3.5.8 LTS；扫码替换为 AVFoundation/ZXing，移除 ML Kit；受发送状态保护的 Imported 副本清理。本机 31 项 core / 848 断言、20 项 Dart、Android 5 项仪器测试与 iOS 5 项 XCTest 通过。
- 远程 macOS 全流程 `35641577661` 成功；Linux TLS 测试缺失头文件、Windows OpenSSL provider CRT 不一致已修复。最新 `4475140` 的三组 CI 被 GitHub 付款/支出上限拒绝启动，需所有者处理，勿反复重跑。
- 许可审计发现既有 ISC、Unicode/ICU、Zlib、libpng、FTL/IJG 等宽松许可超出 PLAN 原名单，具体证据在 `docs/LICENSE_AUDIT.md`，已向所有者询问白名单解释，尚待回复。
- 下一步：完整许可清单/App 法律页、自托管加固与文档、并发/强制 TURN/中继压测；补全 CI 和真机/域名/签名验收。

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
- Flutter 3.47.5 / Dart 3.13.4（`/opt/homebrew/bin`）、CocoaPods；Android SDK 36 / Build Tools 36.0.0 / NDK 28.2.13676358 与 JDK 21 已装，所有者已接受相关许可。

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
tools/build_native.sh && (cd app && flutter run -d macos)   # 桌面 App（先起本地 server）
```
