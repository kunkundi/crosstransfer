# 阶段 5 加固记录

工作分支 `codex/phase5-hardening`。本阶段仍在实施，不能视为发布验收完成。

## WSS 证书身份（2026-09-22）

检查发现信令 TLS 原先只验证受信证书链，未绑定目标 DNS/IP。现在在建立连接前设置 OpenSSL SAN 身份校验：DNS 与 IP 分开验证，禁用部分通配符和仅 Common Name 的旧证书，最低 TLS 1.2。TLS 初始化失败终止连接，所有证书验证错误进入终止状态而不无限重试。

iOS 可用系统信任补齐 OpenSSL 缺失的根证书，但该回退先严格检查已配置 SAN，不覆盖主机名、过期或签名错误。参照 [OpenSSL 验证参数说明](https://docs.openssl.org/3.1/man3/X509_VERIFY_PARAM_set_flags/)。

新增 `core/tests/test_tls_identity.cpp`：生成临时 CA/服务端证书，通过内存 BIO 执行真实 TLS 握手，覆盖 DNS、IPv4、IPv6、错误主机/IP、未知根、过期、仅 CN 和通配符边界；本机 core tests 为 **31 项 / 848 断言通过**。

新增 `tools/run_tls_e2e.py`：临时 Go TLS 信令服务和两个真实 CLI 经强制 WSS 中继传送 1 MiB+37 B 中文文件，SHA-256 一致；同一受信 CA 签发的错误主机名证书在分享注册前被拒绝。临时 CA 只通过子进程 `SSL_CERT_FILE` 使用，不改系统证书库；macOS/Linux CI 执行此项，Windows 执行内存握手测试。

## 继续实施

- 全平台远程回归与 Windows 慢构建诊断。
- 完整传递依赖许可审计、App 内开源许可证页及分发清单。
- 移动端导入副本的占用提示/清理。
- 自托管 TLS/ACME、部署、升级和多接收端/中继负载文档与验证。
- 正式身份/签名/域名、移动真机、16 KB 系统与厂商后台限制需相应资源后补验收。
