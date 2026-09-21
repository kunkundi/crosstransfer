# 阶段 5 加固记录

工作分支 `codex/phase5-hardening`。本阶段仍在实施，不能视为发布验收完成。

## WSS 证书身份（2026-09-22）

检查发现信令 TLS 原先只验证受信证书链，未绑定目标 DNS/IP。现在在建立连接前设置 OpenSSL SAN 身份校验：DNS 与 IP 分开验证，禁用部分通配符和仅 Common Name 的旧证书，最低 TLS 1.2。TLS 初始化失败终止连接，所有证书验证错误进入终止状态而不无限重试。

iOS 可用系统信任补齐 OpenSSL 缺失的根证书，但该回退先严格检查已配置 SAN，不覆盖主机名、过期或签名错误。参照 [OpenSSL 验证参数说明](https://docs.openssl.org/3.1/man3/X509_VERIFY_PARAM_set_flags/)。

新增 `core/tests/test_tls_identity.cpp`：生成临时 CA/服务端证书，通过内存 BIO 执行真实 TLS 握手，覆盖 DNS、IPv4、IPv6、错误主机/IP、未知根、过期、仅 CN 和通配符边界；本机 core tests 为 **31 项 / 848 断言通过**。

新增 `tools/run_tls_e2e.py`：临时 Go TLS 信令服务和两个真实 CLI 经强制 WSS 中继传送 1 MiB+37 B 中文文件，SHA-256 一致；同一受信 CA 签发的错误主机名证书在分享注册前被拒绝。临时 CA 只通过子进程 `SSL_CERT_FILE` 使用，不改系统证书库；macOS/Linux CI 执行此项，Windows 执行内存握手测试。

## OpenSSL LTS 与 Windows 构建诊断（2026-09-22）

所有原生目标统一固定 **OpenSSL 3.5.8**，使用官方发布归档与 SHA-256，替换原 3.3.2。3.5 为 LTS，支持至 2030 年 4 月，见 [官方版本与支持期限](https://openssl-library.org/source/)。升级后 macOS arm64 的 31 项核心测试 / 848 断言和上述两项 WSS 端到端测试通过；其他架构交由本分支 Actions 回归。

阶段 3 桌面回归 `35634141872` 中 Linux 与 macOS 成功，Windows 在 OpenSSL 安装失败后未退出，最终触发 60 分钟任务超时；不能将此轮记为全绿。Windows 配方改用 nmake，构建脚本对每次 xmake 调用设 20 分钟上限并终止超时进程树，CI 始终保留依赖安装失败日志。旧日志不足以确认 JOM 安装失败的完整根因，新流程还需 Windows CI 验证。

本轮回归 `35641577661`：macOS universal 的原生测试、可信 WSS、FFI ⇄ CLI、Dart、Flutter Release 和 DMG 全部通过。Linux 在新增 TLS 测试编译时发现 `<ostream>` 缺失（GCC 无法输出断言中的智能指针），已补齐；macOS 的 3 项 TLS / 543 断言单独复测通过。Windows 诊断产物定位到 `legacy.dll` 的 30 个 `__imp_*` UCRT 符号未解析：静态 libcrypto 已切 `/MD`，provider 对象却未设置 CRT，仍默认 `/MT`。已向 OpenSSL Configure 全局传递所选 `/MD`/`/MDd`，覆盖 provider 和应用对象，待下一轮 Windows 验证。

## 移动扫码依赖替换（2026-09-22）

`mobile_scanner` 的 Android 实现间接带入 ML Kit，受 [额外 Google API 条款](https://developers.google.com/ml-kit/terms) 约束，超出计划的依赖许可范围。已移除插件：iOS 采用系统 AVFoundation QR 元数据，Android 采用 ZXing Android Embedded 4.3.0 / Core 3.4.1（Apache-2.0），完整许可位于 `docs/licenses/`。两端原生界面管理相机生命周期和授权，Dart 统一校验取件码、取消和重试。真机光学实扫仍待设备验收。

- Dart 静态分析无问题，17 项测试通过，含 4 项扫码流程测试。
- Android 4 项仪器测试通过（原 2 项 SAF/分享，加二维码图像解码/桥接和取消/拒绝授权），P2P 与强制中继的 2 项运行时测试通过。
- OpenSSL 3.5.8 三 ABI 重建与检查通过；测试签名 Release APK 约 84.4 MB，15 个原生库，64 位 ELF 与 ZIP 16 KB 对齐检查通过。Gradle Release 依赖树不再包含 ML Kit / Play Services。
- iOS device arm64、simulator arm64/x86_64 静态库与模拟器 App 编译通过，15 项 FFI 符号及 App Group 检查通过；4 项 XCTest 全部通过，记录 `dist/ios-native-20260922-030706.xcresult`。

## 导入副本清理（2026-09-22）

设置页新增 Imported 占用、可清理容量、刷新和明确确认的清理操作。仅接受预览快照内的 UUID 批次；平台文件队列串行处理，删除前重新保护未消费 Inbox，新批次不加入本次清理。复制容量统计不跟随符号链接，删除只移除链接本身。Received 与原始提供器文件不在操作根目录中。

清理前同步查询 core 状态，确认排队的关闭操作与发送线程退出已完成；活动或暂停的发送会阻止清理。整个清理期间阻止新建分享与恢复传输，避免文件检查后重新被使用。

本机 **20 项 Dart 测试、Android 5 项仪器测试、iOS 5 项 XCTest** 通过。新增覆盖确认取消、预览 ID 固定、最新 core 状态与清理期间锁定、待处理分享/新批次/外部链接目标保护、路径穿越拒绝。

## 自托管 HTTP 与容器（2026-09-22）

落地页改用模板和规范化取件码，拒绝非法路径，禁用缓存与 referrer；下载入口仅跳转到配置的 HTTPS URL。可配置只读目录提供两个固定的手机关联 JSON，不开放整个目录。健康探针使用同一份 YAML/环境配置，ACME 模式设置域名 SNI；镜像为非 root 用户准备可写的证书缓存目录。

`go test -race ./...` 与 `go vet ./...` 通过。Docker 镜像构建后，`tools/check_server_container.py` 实测非 root / 只读容器启动、YAML 健康探针、取件页与固定下载跳转、关联文件白名单、默认关闭 metrics、全新 ACME 命名卷 UID/GID 65532。测试只创建并清理自己的容器与卷，没有部署公网服务或申请证书。新增 server CI 保存同一验收入口；CI 仍受账户账单阻塞。

新增中英 README 与 `docs/SELF_HOSTING.md`，涵盖三种 TLS 方式、TURN、防火墙、代理、手机域名关联、升级与回滚。公共服务配额和真实公网 ACME 验收仍待完成。

## 并发压测发现的接收端缺陷（2026-09-22）

8 接收端 × 64 MiB 的强制 TURN 测试暴露重复最终块问题：`HandleBatch` 在提交前一段之前判断后一块是否新块，同批重复块可能在前一段完成校验并关闭文件后仍被写入，误报 `io write failed`。改为先提交不连续段、再判断当前块新旧；同时让 `file_done` 队列与条件变量共享同一互斥锁，消除原等待谓词对另一锁保护数据的读取。

新增确定性测试由 writer 回调把两份最终块放进同一批，并提前送达哈希。旧实现稳定失败，修复后 **32 项 core / 859 断言通过**。大并发还发现 TURN 数据停顿/ICE 超时，正在继续定位，不能将该轮记为整体通过。

## TURN 停顿排查过程

TURN 停顿已复现并采集进程线程栈（本机 `/tmp/ct-turn-deadlock.sample`）。源码中 `agent_send` 的 TURN 分支需要连接锁，原收包路径在同一连接锁内进入传输层，形成与发送/反馈锁的反向等待。ICE 封装已增加有界收包队列和独立交付线程，Close 等待交付结束；新测试用真实本地 ICE 连接阻塞上层回调，同时验证 libjuice API 仍可返回，20 断言通过。复测大流量未再停顿，但发现原强制 TURN 候选过滤可以退回 prflx/P2P；将该模式补成真正中继限制后再做完整验收。

内置 TURN 增加默认 peer 访问策略（参考 [IANA IPv4 特殊用途地址表](https://www.iana.org/assignments/iana-ipv4-special-registry/)）：拒绝私网/回环/CGNAT、链路本地、组播、文档/基准测试和保留地址；IPv6 peer 因当前仅 UDP4 中继而拒绝。受控测试可显式开放 RFC1918、回环、CGNAT，但不能放开链路本地。新增地址边界、IPv4-mapped IPv6 和真实 TURN Allocate/CreatePermission/双向数据测试；默认策略确实阻止回环数据，测试开关下双向数据通过。完整 Go race/vet 通过。

## 严格 TURN 与并发回归（2026-09-22）

原强制模式只过滤信令中的候选，但 libjuice 可自行发现并提名直连 prflx 候选。新增 `relay_only` 配置，并在 libjuice 配对入口拒绝非本地 relay 候选。ct1 补丁、完整对应源码及 MPL 文本随各平台分发；`tools/check_libjuice_source.py` 从固定哈希的官方归档应用补丁，逐文件验证随包源码，同时检查许可原文与公告哈希。额外测试绕过应用的信令过滤，直接把可达 host 候选送给 libjuice，验证强制模式仍拒绝直连。全量 **34 项 core / 889 断言通过**。

新增 `tools/run_transfer_load.py`：独立临时 CA、受信 WSS、独立服务端/客户端进程和状态目录；每个接收端校验 SHA-256、空文件/空目录/中文路径，双方最终传输路径必须与测试场景一致，且服务端 peer/share/session 归零。CI 已接入 macOS/Linux 的 4 × 8 MiB 回归，远程执行仍受 GitHub 账单问题阻挡。

本机 macOS arm64，8 接收端 ×（64 MiB + 814 字节），严格 TURN 连续三轮、WSS 中继和 P2P 均通过。测量包含建连与退出，每轮核对 536,877,424 字节；数据仅代表本机回环回归，不代表公网容量或稳定性能基线。

| 场景 | 完成时间 | 聚合 MiB/s | 服务端峰值 RSS | 发送端峰值 RSS |
| --- | ---: | ---: | ---: | ---: |
| 严格 TURN 第 1 轮 | 83.969 s | 6.098 | 24.3 MiB | 63.6 MiB |
| 严格 TURN 第 2 轮 | 53.917 s | 9.496 | 22.6 MiB | 61.8 MiB |
| 严格 TURN 第 3 轮 | 18.702 s | 27.378 | 24.6 MiB | 65.6 MiB |
| WSS 中继 | 22.324 s | 22.935 | 24.3 MiB | 77.3 MiB |
| P2P | 9.190 s | 55.714 | 18.8 MiB | 173.3 MiB |

本机原始报告 `dist/load-phase5-strict-turn-v2.json`。TURN 每轮实际 16 个 allocation；客户端断开后它们暂留至 TURN 生命周期超时，未宣称 allocation 立即释放。各轮无 ICE 互锁、误写已校验文件或路径退回直连。TURN 吞吐波动明显，公网配额/长期负载与吞吐调优仍待后续验证。

2026-09-22 的最新远程回归（提交 `4475140`，Desktop `35644512582`、Android `35644512598`、iOS `35644512727`）均被 GitHub 拒绝启动：账户付款或 Actions 支出上限需要所有者处理。不是代码执行失败；在账单状态恢复前不反复重跑。Windows CRT 修复与最后的 Linux 回归尚未获得远程验证。

- 全平台远程回归与 Windows 慢构建诊断。
- Windows/Linux 最终分发包的许可和系统依赖门禁验收。
- 公共服务资源配额、长期负载和真实公网 ACME 验收。
- 正式身份/签名/域名、移动真机、16 KB 系统与厂商后台限制需相应资源后补验收。


## 通知与许可分发（2026-09-22）

Android 通知聚合插件带入 `desugar_jdk_libs 2.1.4`（GPL-2.0 with Classpath Exception）。已移除两者，Android 使用 NotificationManager，Apple 使用 UserNotifications，仅保留 Linux/Windows 的 BSD 平台通知插件。Android 新增系统通知内容、渠道和点击 Intent 的仪器测试，**6 项通过**；iOS **5 项 XCTest 通过**。双方原生库已重建，包含严格 TURN 与接收队列修复。

所有者已授权既有 ISC、Unicode/ICU、Zlib、libpng、FTL/IJG、public-domain 与 Linux 系统 GTK/GLib 动态链接例外；具体限制已同步 PLAN。App 设置增加法律页，包含完整原生/Android 补充文本、Flutter 生成的许可清单，以及 libjuice ct1、dbus、Dart gtk 三份完整 MPL 源码的离线导出。103 项 pub 声明闭包、68 个 Android Maven 坐标、15 个 Go 模块和原生依赖均记录版本/来源/哈希证据，详见 LICENSE_AUDIT。

**24 项 Dart 测试通过**，新增手机尺寸布局下三个源码归档与随包原始字节一致的导出验证。Android release 解析图和依赖文本检查通过；已增加源码/文本校验、依赖输入漂移门禁与 Linux 系统库分发边界检查。Windows/Linux 的产物级验收仍等待 CI 恢复。

## 限速中继回归（2026-09-22）

4 接收端 ×（16 MiB + 814 字节），每连接 WSS 中继限速 1 MiB/s，实际丢弃 31,940 个受限数据帧。全部接收端哈希与空文件/中文路径一致，服务端 peer/share/session 回收为零。总耗时 72.032 秒，聚合 0.889 MiB/s；发送端峰值 RSS 33.1 MiB，服务端 22.0 MiB。报告为本机 `dist/load-phase5-limited-final.json`，是回环限速恢复验收，不代表公网容量。

## macOS AOT 工具链兼容（2026-09-22）

新增法律页后的完整程序触发 Flutter 3.47.5 上游 #191575：框架 `_window_macos.dart` 的 `_Rect` 在 AOT 快照引用中仍存在，但 class ID 已被裁掉。普通 Release 构建失败；关闭 TFA 也因缺少分发表元数据失败，未保留这组无效参数。

在独立 SDK 副本对 6 个 FFI 类型添加 entry-point 保留标记后，universal Release App 构建成功（66.9 MB）。`tools/build_macos_app.py` 固定版本/原文哈希、显式刷新 package_config、构建后恢复原 SDK 解析，已重复执行通过；全局 Flutter SDK 的 git diff 为空。该处理随 CI 固定版本使用，升级需重新验证并移除。完整许可与三份源码共 20 项法律资产的最终 App 校验通过。


本轮最终产物验证：Android Release APK 85.5 MB，15 个原生库、3 个引擎 ABI、64 位 ELF/ZIP 16 KB 对齐、测试签名、20 项法律/源码资产通过，DEX 不含已移除运行库；模拟器 P2P/WSS 中继两项实际 FFI 收发再次通过。iOS 模拟器 App 重建后 20 项法律资产、15 项 FFI 导出、分享扩展和 App Group 一致性通过。

macOS local-test DMG 的 ad-hoc 签名、镜像校验、法律资产通过。系统 Launch Services 启动后，冷启动和热启动链接收件均验证所有 SHA-256、中文路径与空目录。原验收脚本直接执行二进制可能未注册为运行中的 App，随后 `open -a` 会另起未隔离实例；已改用专门的 Launch Services 启动器传递隔离环境，并在结束时只关闭自己启动的应用。该测试修复通过新 DMG 复测，未把原超时当作成功。


## 服务容量和带宽配额（2026-09-22）

按照 PLAN 增加信令连接全局/每 IP 上限、会话全局/每 peer 上限，以及内嵌 TURN 实际 relay socket 上限。WebSocket 升级失败与断开释放名额；会话满时不消费 once 码，已占用名额的会话仍可按 token 恢复。WSS 发送队列限制 512 帧且不超过 4 MiB；中继报文满时丢弃，可靠控制消息无法排队则关闭慢连接。

TURN relay socket 的检查与创建在同一把锁内，底层绑定失败不消耗名额，Close 通过 once 保证只释放一次。每 allocation 和全局令牌桶覆盖收/发两个方向，超额按 UDP 丢包处理，未改变原协议。WSS 新增独立全局限速。数量上限为正、带宽 0 显式关闭；默认值与计量口径记录在 SELF_HOSTING 的配额表。新增容量拒绝、实际 socket、有效载荷字节及队列/限速丢弃指标。

完整 `go test -race ./...` 与 `go vet ./...` 通过。新增验证包括真实 WebSocket 503 与释放、失败升级不泄漏、发送队列字节限制、once 码保留/续传与恢复、跨 peer 全局 WSS 限速、32 个并发 socket 申请只允许 2 个、底层绑定失败/重复 Close，以及真实 TURN Allocate → 拒绝 → Refresh(0) → 再分配 → 服务关闭回收。

本机用 `/usr/bin/openssl`（LibreSSL）生成临时 CA，Python 严格证书验证保持开启。补全 SKI/AKI 后，4 接收端 ×（8 MiB + 814 字节）的 5 场景全部通过；每场景校验 33,557,688 字节，peer/share/session 均回收为零。报告 `dist/load-phase5-quotas.json`：

| 路径 | 耗时 | 聚合 MiB/s | 限速丢弃 |
| --- | ---: | ---: | ---: |
| P2P | 2.228 s | 14.361 | 0 |
| TURN 默认配额 | 2.731 s | 11.719 | 0 |
| TURN 每 allocation 1 MiB/s、全局 2 MiB/s | 61.777 s | 0.518 | 36,576 |
| WSS | 1.943 s | 16.471 | 0 |
| WSS 每连接 1 MiB/s | 39.294 s | 0.814 | 31,678 |

TURN 计量会对经过两个 relay socket 的同一数据分别计数，不能将配置字节率等同于端到端文件吞吐。该结果为回环完整性/恢复验证，不代表公网容量。对应限速场景已加入默认 CI 回归。

## 远程矩阵恢复（2026-09-22）

推送 `62c43f4` 后 GitHub 已重新执行任务，无需手动重跑。Server `35654293364` 成功；Desktop `35654293360` 中 Linux 全流程成功（34 项 core、24 项 Dart、并发路径、可信 WSS、FFI、deb 和安装后收件）。Windows 的源码比对失败来自脚本生成文本使用平台 CRLF，已改为固定 UTF-8/LF；macOS 并发测试的临时证书缺少 AKI，已显式加入 SKI/AKI，且本机 LibreSSL 严格验证复测通过。两项工具修复为 `726bc03`，仍需下一轮矩阵确认。Android `35654293259` 已全部成功：三 ABI 原生库、24 项 Dart、Release APK/许可门禁、6 项仪器测试与 P2P/WSS 两项 FFI 实际收发。iOS `35654293285` 也已全部成功：device/simulator 原生库、Dart、未签名 Release、模拟器 App、资产/ABI 检查和 5 项 XCTest。

本机 iOS 最新未签名 Release App 30.1 MB 已成功，20 项法律资产、15 项 FFI 导出、扩展与 App Group 均通过。正式签名、真机、公开域名及真实 ACME 验收仍待相应资源。

资源配额版本容器 `crosstransfer/ctserver:phase5-quota-check` 构建成功；只读/非 root 运行、YAML 健康探针、固定落地/下载/关联文件、默认私有 metrics 和 ACME 卷权限回归通过。本机使用过的 Android/iOS 模拟器已关闭，SDK 与测试设备配置保留。
