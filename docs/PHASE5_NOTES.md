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

## 剩余工作

内置 TURN 增加默认 peer 访问策略（参考 [IANA IPv4 特殊用途地址表](https://www.iana.org/assignments/iana-ipv4-special-registry/)）：拒绝私网/回环/CGNAT、链路本地、组播、文档/基准测试和保留地址；IPv6 peer 因当前仅 UDP4 中继而拒绝。受控测试可显式开放 RFC1918、回环、CGNAT，但不能放开链路本地。新增地址边界、IPv4-mapped IPv6 和真实 TURN Allocate/CreatePermission/双向数据测试；默认策略确实阻止回环数据，测试开关下双向数据通过。完整 Go race/vet 通过。

2026-09-22 的最新远程回归（提交 `4475140`，Desktop `35644512582`、Android `35644512598`、iOS `35644512727`）均被 GitHub 拒绝启动：账户付款或 Actions 支出上限需要所有者处理。不是代码执行失败；在账单状态恢复前不反复重跑。Windows CRT 修复与最后的 Linux 回归尚未获得远程验证。

- 全平台远程回归与 Windows 慢构建诊断。
- 完整传递依赖许可审计、App 内开源许可证页及分发清单。
- 自托管 TLS/ACME、部署、升级和多接收端/中继负载文档与验证。
- 正式身份/签名/域名、移动真机、16 KB 系统与厂商后台限制需相应资源后补验收。
