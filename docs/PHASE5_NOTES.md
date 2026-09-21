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

## 继续实施

### 移动扫码依赖替换（2026-09-22）

`mobile_scanner` 的 Android 实现间接带入 ML Kit，受 [额外 Google API 条款](https://developers.google.com/ml-kit/terms) 约束，超出计划的依赖许可范围。已移除插件：iOS 采用系统 AVFoundation QR 元数据，Android 采用 ZXing Android Embedded 4.3.0 / Core 3.4.1（Apache-2.0），完整许可位于 `docs/licenses/`。两端原生界面管理相机生命周期和授权，Dart 统一校验取件码、取消和重试。真机光学实扫仍待设备验收。

- Dart 静态分析无问题，17 项测试通过，含 4 项扫码流程测试。
- Android 4 项仪器测试通过（原 2 项 SAF/分享，加二维码图像解码/桥接和取消/拒绝授权），P2P 与强制中继的 2 项运行时测试通过。
- OpenSSL 3.5.8 三 ABI 重建与检查通过；测试签名 Release APK 约 84.4 MB，15 个原生库，64 位 ELF 与 ZIP 16 KB 对齐检查通过。Gradle Release 依赖树不再包含 ML Kit / Play Services。
- iOS device arm64、simulator arm64/x86_64 静态库与模拟器 App 编译通过，15 项 FFI 符号及 App Group 检查通过；4 项 XCTest 全部通过，记录 `dist/ios-native-20260922-030706.xcresult`。

## 待完成

- 全平台远程回归与 Windows 慢构建诊断。
- 完整传递依赖许可审计、App 内开源许可证页及分发清单。
- 移动端导入副本的占用提示/清理。
- 自托管 TLS/ACME、部署、升级和多接收端/中继负载文档与验证。
- 正式身份/签名/域名、移动真机、16 KB 系统与厂商后台限制需相应资源后补验收。
