# iOS 构建与验收（Phase 3）

iOS 15.0+，Flutter 3.47.5 / Dart 3.13.4、Xcode、CocoaPods、xmake 3.1.0。使用静态原生引擎，不加载 dylib。默认 Bundle ID 暂沿用桌面的 `com.crosstransfer.crosstransfer`；正式标识与域名仍需项目所有者提供。

## 构建

```sh
tools/build_ios_native.sh
cd app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build ios --release --no-codesign
flutter build ios --simulator --debug
```

脚本构建 device arm64、simulator arm64 / x86_64，合并为 `app/ios/native/crosstransfer_native.xcframework`。Flutter 的通用模拟器构建会请求 arm64 与 x86_64 两个 slice，故默认两者均构建。`CT_IOS_SIM_ARCHS` 仅供明确限制 Xcode 构建架构时使用。

根 xmake 目标将 core、MiniRTC、KCP、libjuice、miniupnpc、libsrtp、OpenSSL 合并进静态 archive。xmake 3.1 的依赖缓存不区分相同架构的真机与模拟器，故将完整目标 triple 写入包编译选项，防止混用。Podspec 以链接器 `-u` 保留公开 C API，Dart 使用 `DynamicLibrary.process()`；构建后需检查最终可执行文件中的全部 15 个公开 `Ct*` 符号。静态库产物不提交 Git。

主 App 与 ShareExtension 使用同一 App Group。未签名构建可验证编译、链接和 bundle 结构；真机安装需要有效的 Apple Developer Team 和匹配两个 target 的 provisioning profile。

## Bundle ID、App Group 与 Universal Link

```sh
python3 tools/configure_ios.py \
  --bundle-id com.yourcompany.crosstransfer \
  --team-id YOURTEAMID \
  --link-domain transfer.example.com
```

命令更新 `Flutter/Branding.xcconfig` 和两份 entitlements，生成 `dist/ios-links/.well-known/apple-app-site-association`。Apple Developer 中需注册主 App、`<bundle-id>.ShareExtension` 和 `group.<bundle-id>`；主 App 启用 Associated Domains，两 target 启用 App Groups。命令不注册账号资源，也不上传站点。

将 AASA 文件以 `application/json`、HTTPS、无重定向部署到指定域名的 `/.well-known/apple-app-site-association`，在 App 设置中填入同一个链接域名。只有完成签名与域名关联后才能做 Universal Link 真机验收。未配置域名时仍可用 `crosstransfer://r/<code>` 或扫码/手输取件码。`FlutterDeepLinkingEnabled=false`，由 `app_links` 统一处理冷启动与已有 scene 的链接。

## iOS 行为

- 手机宽度使用底部导航；大屏使用侧栏。扫码只接受有效取件码/链接，扫描成功一次即关闭；相机权限失败时可返回粘贴链接。
- 默认接收目录为 `Documents/Received`，可在系统“文件”中访问。暂不允许 core 直接写入外部安全作用域目录；完成后用“导出到文件”导出接收目录。文件选择器导入本地副本后交给 core。
- 分享扩展从 `NSItemProvider` 复制文件，在共享容器原子提交 manifest；回到 App 后复制到 `Documents/Imported/<batch-id>`，点击“生成取件码”发送。支持多文件、图片、视频及取件链接。失败不提交半份清单，确认处理后移除 App Group 批次；发送副本保留在 Documents/Imported，便于后续发送或通过“文件”管理。
- 分享扩展提示用户打开 CrossTransfer，不使用响应链调用 UIApplication 的跳转技巧。该实现替代原规划中的 iOS `share_handler` 插件；Android 分享入口在阶段 4 单独实现。
- 有活动分享/传输时禁止自动锁屏；切后台调用 `beginBackgroundTask`。系统到期时结束断言并请求 core 暂停活动传输，前台显示提示，由用户继续。没有设置音频、定位等无关后台模式；大文件仍需保持前台。
- 中/英通知、相机与本地网络权限说明已接入。首次 release 启动需配置自己的信令服务。

## 模拟器验收

先启动任意已安装的 iPhone Simulator，构建本机 `ct_cli`：

```sh
xmake f -p macosx -a arm64 -m release --ct_cli=y --ct_tests=n --ct_native=n --target_minver=12.0 -o build -y
xmake build -y ct_cli
mkdir -p dist
python3 tools/ios_e2e.py --device booted
```

脚本启动独立信令服务、安装 App，临时隔离 Application Support 中的测试配置并在结束后恢复原目录，通过两次 scheme 激活接收 CLI 的文件，校验空文件、空目录、中文路径、多块文件 SHA-256 和临时文件清理。首次冷启动 scheme 打开可能需要在模拟器点击系统“打开”确认；全新模拟器的通知权限也需观察。测试 fixture 留在模拟器 Documents 下供检查，进程结束后停止服务与 App。截图输出 `dist/ios-receive.png`。

`.github/workflows/ios.yml` 提供未签名真机构建、模拟器构建、Dart 检查，以及 `tools/test_ios_native.sh <UDID>` 原生运行时测试（15 个 FFI 符号、P2P、强制 WSS 中继、连续失败重连/退出；含空文件/目录和中文路径的完整性校验）。scheme 的首次系统确认属于本地交互验收。相机实拍、系统分享菜单、锁屏后系统真实到期、通知权限和 Universal Link 最终都需要签名真机验收；模拟器不能证明这些行为在真机上全部通过。

实现依据：[Apple 后台执行时间](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)、[Apple Share Extension](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)、[AVFoundation 二维码元数据](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput)。
