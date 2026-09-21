# 阶段 3 iOS 实施记录

## 2026-09-22

工作分支 `codex/phase3-ios`；构建与签名配置见 [`IOS_BUILD.md`](IOS_BUILD.md)。

已实现：

- iOS 15.0+ Runner / ShareExtension 工程；静态 XCFramework 包含 device arm64 与 simulator arm64/x86_64，合并 core、MiniRTC 及所有静态依赖；CocoaPods 集成，Dart 通过 `DynamicLibrary.process()` 解析公开 API。
- 修复 xmake 3.1 同架构真机/模拟器依赖缓存混用：将完整 Apple target triple 纳入依赖配置；补齐 umbrella 的静态依赖，避免只合并项目 archive 而漏掉 OpenSSL/libjuice/KCP。
- 手机底部导航、窄屏设置与接收表单、扫码及相机失败提示、系统分享链接、中/英通知。系统链接成功接收后不弹键盘；对用户显示 Documents 路径，隐藏沙箱内部路径。
- 默认 `Documents/Received`，系统“文件”可见，完成后可导出目录；不向 core 传入生命周期不受控的外部目录安全作用域。
- 原生分享扩展从 NSItemProvider 复制文件，在 App Group 原子提交批次。主 App 回前台读入 Documents/Imported，用户生成取件码；允许导入文件与取件链接，不使用 UIApplication 响应链跳转。文件复制在后台队列运行，先写临时副本再改名，避免中断后发送半份文件。
- `UIScene` 生命周期驱动后台任务；活动传输期间禁止自动锁屏，退后台申请有限执行时间，到期请求暂停并结束断言，回前台提示用户继续。
- `configure_ios.py` 生成 Bundle ID / App Group / Associated Domains 配置及 AASA 文件；正式身份和域名未确定时保留 scheme 收件。命令不上传或注册 Apple 资源。
- 修复不可达服务触发的 WebSocket 重连崩溃：心跳与重连对同一条件变量使用同一把锁，I/O 线程持有旧 endpoint 直到退出，阻止 shutdown 后创建重连线程。新增桌面与 iOS 连续失败重连/退出回归。
- `.github/workflows/ios.yml` 包含未签名真机 / 模拟器构建、Dart 检查、公开符号检查、XCTest 运行时 FFI、P2P/强制中继传输与失败重连。

本机验证：

| 验证 | 结果 |
| --- | --- |
| 静态 XCFramework | device arm64、simulator arm64/x86_64 均成功 |
| Flutter analyze / test | 零问题；13 项测试通过（新增后台活动判断与三页面 375 px 布局） |
| iOS release 未签名 | 构建成功，App 约 28.8 MB |
| iOS debug simulator | 构建成功，嵌入 ShareExtension、App Group 一致 |
| 最终 App 的 C ABI | 真机 / 模拟器均包含 15 个公开 FFI 符号 |
| XCTest 动态符号与传输 | 4 项通过：process dlsym + CtVersion、P2P、强制 WSS relay、不可达服务连续重连与退出；1 MiB 多块文件、空文件、空目录、中文路径完整性，且验证实际路径 p2p / relay |
| core tests | 28 项测试、305 条断言通过，含 WebSocket 失败重连回归 |
| CLI → iOS scheme 收件 | 冷启动 / 已运行 App 两次通过；空文件/目录、中文路径、3 MiB + 37 B 文件 SHA-256 一致 |
| “文件” → 分享扩展 → Flutter/core → CLI | 通过；188,000 B 文本文件 SHA-256 为 `79895570f434a25337054f564d181dc06ee49cf379b0b9b36cfc1cfe1bf7089e` |
| 首次系统交互 | 模拟器实际观察到通知权限和首次 scheme“打开”提示；点击后收件成功 |

测试工具：`build_ios_native.sh`、`check_ios_native.py`、`test_ios_native.sh <UDID>`、`ios_e2e.py --device <UDID>`。XCTest 可无人值守执行；scheme 的首次系统确认保留为交互验收，不用脚本绕过系统提示。截图在本地 `dist/ios-receive.png`、`dist/ios-share.png`。修复后 XCTest 结果在 `dist/ios-native-20260922-014434.xcresult`；路径验证记录传输事件，避免完成后会话已移除的查询竞态。

远程验收：[Actions 35634079792](https://github.com/kunkundi/crosstransfer/actions/runs/35634079792) 全部通过，对应 `b109234`；含三 slice 原生构建、Dart 分析/测试、device 与 simulator Flutter 构建、15 项 ABI 检查及模拟器 XCTest。

尚未完成的验收边界：

- 正式 Bundle ID、Apple Team/App Group provisioning、接收域名与 AASA 部署待项目所有者确定；当前使用临时桌面同名 ID，release 产物未签名。
- 未连接真实 iPhone/iPad，摄像头实扫、系统实际后台时间耗尽、锁屏网络、Universal Link 域名关联与通知真机行为尚未验收。
- 导入文件在主 App Documents/Imported 中保留，用户可通过“文件”管理；自动配额/陈旧临时文件回收留给阶段 5 加固。

阶段 5 补充：通知、扫码、导入清理和许可证分发已加固，[Actions 35654293285](https://github.com/kunkundi/crosstransfer/actions/runs/35654293285) 完整通过，含 24 项 Dart、device/simulator App、法律资产/ABI 与 5 项 XCTest。Android 移植已完成；当前继续真机/域名/签名与公共服务验收，详见 [阶段 5 记录](PHASE5_NOTES.md)。
