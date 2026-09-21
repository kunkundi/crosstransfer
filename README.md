# CrossTransfer

[English](README_EN.md)

商业闭源的跨平台 P2P 文件传输工具，支持 Windows、macOS、Linux、iOS 和 Android。发送方选择文件或目录，接收方通过取件码、链接或二维码接收。

- Flutter 界面与 Dart FFI；共享 C++ core 和本仓库维护的 MiniRTC 数据传输引擎。
- P2P 优先，TURN-UDP 和 WSS 中继兜底；DTLS-SRTP 保护传输内容。
- 中文/英文、目录与空文件、进度、取消、断线续传、多接收端分享。
- 手机系统分享、原生扫码、文件导出、导入副本清理；Android 前台传输服务，iOS 有限后台执行时间。
- 自托管 Go 服务，无账号、不存文件。第一版信任服务器转发的指纹，尚未实现 SPAKE2 口令认证。

目前阶段 5 加固进行中。工程测试与构建状态见 [CLAUDE.md](CLAUDE.md) 和 [阶段 5 记录](docs/PHASE5_NOTES.md)；正式签名、生产域名与真机验收尚未完成，当前安装包为开发/测试产物。

## 开发入口

依赖 xmake、C++17 工具链、Go 1.25、Flutter 3.47.5。各平台额外要求和完整命令分别见：

- [桌面构建与打包](docs/DESKTOP_BUILD.md)
- [iOS 构建与签名配置](docs/IOS_BUILD.md)
- [Android NDK、SDK 与构建](docs/ANDROID_BUILD.md)
- [服务自托管、TLS、ACME 与手机链接](docs/SELF_HOSTING.md)

核心与 CLI 的本机构建：

```sh
xmake f -m release --ct_cli=y --ct_tests=y -y
xmake build -y core_tests ct_cli
xmake run core_tests
```

服务端检查：

```sh
cd server
go test -race ./...
go vet ./...
CT_LISTEN=127.0.0.1:8080 CT_TURN_PORT=0 go run ./cmd/ctserver
```

CLI 位于 `build/<platform>/<arch>/release/ct_cli`，Windows 带 `.exe` 后缀。先在一个终端执行 `ct_cli share <path> --server 127.0.0.1:8080`，再在另一个终端执行 `ct_cli receive <code> --dir <destination> --server 127.0.0.1:8080`。公网必须配置可信 TLS 并传 `--tls`。

## 项目资料

[完整规划](docs/PLAN.md) · [信令协议](docs/SIGNALING.md) · [文件传输协议](docs/TRANSFER_PROTOCOL.md) · [第三方声明](THIRD_PARTY_NOTICES.md) · [许可审计](docs/LICENSE_AUDIT.md)

本项目受 [专有许可](LICENSE) 约束。第三方组件保留各自版权与许可；完整分发清单及 App 内法律页正在阶段 5 补齐。
