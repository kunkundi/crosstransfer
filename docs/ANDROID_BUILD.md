# Android 构建与验收

基线：Flutter 3.47.5 / Dart 3.13.4、JDK 21、xmake 3.1.0、Android SDK 36、Build Tools 36.0.0、NDK 28.2.13676358、Go 1.25。最低 Android 7.0 / API 24，支持 arm64-v8a、armeabi-v7a、x86_64。

## 原生库与 APK

先按 Android SDK 安装器要求接受对应许可；本项目所有者已授权当前开发环境及 CI 安装这些组件。macOS 示例：

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
sdkmanager 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358' 'platform-tools'
tools/build_android_native.sh
for abi in arm64-v8a armeabi-v7a x86_64; do
  python3 tools/check_android_native.py "app/android/app/src/main/jniLibs/$abi/libcrosstransfer_native.so"
done
cd app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
cd ..
python3 tools/check_android_apk.py app/build/app/outputs/flutter-apk/app-release.apk
```

Gradle 会按插件需要安装 SDK 34/35 和 CMake。单架构调试可用 `CT_ANDROID_ABIS=arm64-v8a tools/build_android_native.sh`，随后 `flutter build apk --debug --target-platform android-arm64`。每个 xmake 配置共用仓库 `.xmake`，不要在同一 checkout 并行运行多个架构构建。JNI 库不提交 Git，Gradle `preBuild` 检查所需文件是否存在。

检查项：15 个 Ct FFI 导出、引擎三个 ABI 的 16 KB LOAD 对齐、仅链接 Android 系统动态库；APK 内所有 64 位原生依赖的 16 KB LOAD/RELRO 安全边界、未压缩 ZIP 条目对齐和有效签名。ARMv7 第三方库可保持 4 KB ELF 对齐。依据：[Android 16 KB 页面指南](https://developer.android.com/guide/practices/page-sizes)。静态检查不能代替 16 KB 系统实机/模拟器运行验收。

## 签名与 App Link

默认包名 `com.crosstransfer.crosstransfer` 是开发占位。未提供以下环境变量时，Release APK 使用调试签名，仅作本地/CI 测试：

- `CT_ANDROID_KEYSTORE`：所有者 keystore 的绝对路径。
- `CT_ANDROID_KEY_ALIAS`。
- `CT_ANDROID_STORE_PASSWORD`。
- `CT_ANDROID_KEY_PASSWORD`。

四项必须同时提供；密钥文件和密码不提交仓库。正式包名、域名和发布证书确定后：

```sh
python3 tools/configure_android.py --application-id com.example.transfer \
  --link-domain transfer.example.com --sha256 '<APK 签名证书 SHA-256>'
```

脚本更新 applicationId 和 HTTPS intent filter，并生成 `dist/android-links/.well-known/assetlinks.json`，不会发布文件。将其部署到同域名 HTTPS 的 `/.well-known/assetlinks.json`，之后使用 `adb shell pm verify-app-links --re-verify <包名>` / `adb shell pm get-app-links <包名>` 验证。使用 Google Play App Signing 时应填写分发签名证书指纹。未配置域名时，`crosstransfer://r/<code>` 可用。

## 运行时验收

已启动的专用 Android 测试设备示例：

```sh
tools/test_android_native.sh emulator-5554
```

脚本启动隔离 Go 信令服务，通过自建的 `adb reverse tcp:19090` 映射运行 Dart FFI 集成测试，并在结束时清理服务/映射。覆盖真实 P2P、强制中继、1 MiB+37 字节内容、中文路径、空文件/空目录与文件字节一致性。

SAF/系统分享桥接仪器测试：

```sh
cd app/android
ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest -Ptarget-platform=android-arm64
```

测试 APK 内的独立 DocumentsProvider 提供临时 URI 授权；ActivityMonitor 仅代替选择器的人工选择，仍经过实际 Activity result、ContentResolver、后台复制和持久化。测试 provider 不进入产品 APK。报告位于 `app/build/app/reports/androidTests/connected/debug/`。

验证完整 App 的冷/热启动链接、CLI → Android 接收和后台前台服务：

```sh
# 集成测试 APK 的入口不同，先重新构建安装实际 App。
cd app
flutter build apk --debug --target-platform android-arm64
adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk
cd ..
python3 tools/android_e2e.py --device emulator-5554 --cli build/macosx/arm64/release/ct_cli
```

此脚本要求可 `run-as` 的调试包，临时备份并最终恢复 App `files` 配置；接收目录和端口映射仅清理本次创建的内容。每次收取 8 MiB+37 字节、Unicode 与空目录，校验 SHA-256，检查服务启动/结束，并测试退到桌面后的接收。异常退出后优先检查备份，勿对日常使用设备执行 `pm clear`。

## 文件与后台行为

- SAF 文件/目录、ACTION_SEND / ACTION_SEND_MULTIPLE 均先复制到私有持久 `files/Imported/<UUID>`。核心始终读取 POSIX 路径，不依赖长期 URI 权限。
- 系统分享在原子 Inbox 清单提交后显示确认卡片；确认发送后删除清单，保留源副本供当前分享使用。
- 收件保存到 `app_flutter/Received`；用户主动通过 SAF 选择目录导出。每次创建新目录，不覆盖目的地已有文件。
- Application 持有 FlutterEngine，Activity 重建/退出不销毁正在使用的 FFI 引擎。活动工作使用 dataSync 前台服务、通知及有限时长唤醒锁；系统超时通知 Dart 暂停并停止服务。
- 依赖 `desktop_drop` 尚使用 Kotlin Gradle Plugin；当前 Flutter 给出迁移提醒，构建可通过。模板兼容开关保留，升级 Flutter 前应复核插件支持情况。

正式发布前仍需真机相机扫码、厂商后台策略、系统前台服务配额到期、16 KB 系统运行以及正式签名/App Link 联调。
