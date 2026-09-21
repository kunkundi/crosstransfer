# 阶段 4 Android 实施记录

## 2026-09-22

工作分支 `codex/phase4-android`；构建、签名和运行时验收命令见 [`ANDROID_BUILD.md`](ANDROID_BUILD.md)。

实现：

- xmake/NDK 构建 arm64-v8a、armeabi-v7a、x86_64，静态合入 OpenSSL/libjuice/libsrtp 等依赖，`jniLibs` 打包，保留 15 个 Ct FFI 符号。
- 修复 NDK 交叉编译使用宿主 ranlib 导致的归档损坏；为 Android 配置 llvm-ranlib。用共享库链接选项隐藏 OpenSSL archive 内部符号，解决 ARMv7 汇编重定位错误。
- Android OpenSSL 信令加载 Conscrypt APEX 系统根证书，老系统使用 `/system/etc/security/cacerts`；逐张导入，避免 Android 历史证书 hash 与 OpenSSL 3 的目录查找方式不一致。
- API 24+ Runner，Application 持有 FlutterEngine；dataSync 前台服务、通知与有界唤醒锁，系统到期停止服务并请求暂停。通知权限在 Activity 就绪后申请，避免 Application 提前启动 Dart 导致插件空 Activity 异常。
- SAF 选文件/目录、系统分享批次导入、原子 Inbox、持久私有文件副本；接收后 SAF 导出到新目录。目录深度/数量有界，同名导入不覆盖。
- 手机发送、接收、设置接入 Android 路径与文件桥接；scheme 支持冷/热启动。App Link 配置脚本生成 assetlinks.json，正式证书和域名确定后部署。
- 三架构 APK、环境变量正式签名配置、ELF/ZIP 对齐检查；测试 APK 的 DocumentsProvider 和 ActivityMonitor 验证实际 URI 授权/复制/导出合同，不进入产品包。

已完成的本机验收：

| 项目 | 结果 |
| --- | --- |
| 三种 ABI 原生引擎 | 全部编译通过，15 项 FFI 导出、16 KB LOAD 对齐、仅系统动态依赖 |
| Flutter analyze / unit tests | 零问题，13 项测试通过 |
| Android API 35 arm64 运行时 FFI | P2P / 强制中继 2 项通过；1 MiB+37 B、Unicode、空文件/目录与实际路径检查 |
| CLI → Android 完整 App | 冷/热启动 scheme 两次通过；各 8 MiB+37 B、空文件/目录与 SHA-256 校验 |
| 后台与服务生命周期 | 热启动接收期间退到桌面，继续完成；前台服务随工作启动，结束后退出 |
| SAF / 系统分享桥接 | 2 项仪器测试通过：目录导入/导出完整性、源删除后副本有效、系统多文件分享重名不覆盖、Inbox 确认保留源文件 |
| Release APK | 三 ABI，约 99.3 MB；24 个原生库，所有 64 位 ELF 与 ZIP 16 KB 对齐、有效调试签名 |

记录：`dist/android-receive.png`；本机仪器测试报告 `app/build/app/reports/androidTests/connected/debug/`。远程原生三架构 [Actions 35636445939](https://github.com/kunkundi/crosstransfer/actions/runs/35636445939) 全绿；新增完整 Flutter APK/模拟器流水线待运行结果。

验收边界与后续：

- 默认 applicationId 为占位；正式 keystore、分发渠道证书、域名和 assetlinks.json 尚未部署。当前 Release APK 使用测试签名。
- 尚无 Android 真机验收；相机实扫、OEM 后台限制、6 小时 dataSync 配额耗尽和 16 KB 页面系统的运行时仍待验证。静态对齐通过不等于这些运行场景通过。
- SAF 测试使用真实跨 UID DocumentsProvider 和临时 URI 授权，选择器人工操作由 ActivityMonitor 返回结果；真实文件管理器界面/不同云盘提供器仍需人工验收。
- 导入副本的占用提示/清理、完整传递依赖许可审计（含 Android 扫码 SDK）、TLS 主机名验证、全平台并发/弱网和服务部署继续在阶段 5 完成。
