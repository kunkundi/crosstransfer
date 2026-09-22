# 桌面构建与安装包（Phase 2）

> 商用构建必须指定 `CT_SERVICE_HOST`；本页的回环/模拟器验收需先设置 `CT_DEVELOPER_MODE=y`（PowerShell：`$env:CT_DEVELOPER_MODE="y"`），仅供内部开发。详见[服务发行配置](CLIENT_SERVICE.md)。

三平台使用 `app/pubspec.lock` 锁定 Dart 依赖。工具版本为 Flutter 3.47.5 / Dart 3.13.4、xmake 3.1.0；端到端验收还需要 Go 1.25 和 Python 3。先构建 native，再构建 Flutter。`CT_NATIVE_LIB` 仅用于开发检查，安装包内必须自带共享库。

## macOS 12.0+

```sh
tools/build_native.sh macosx universal
cd app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
python3 ../tools/build_macos_app.py
cd ..
tools/package_macos.sh
```

需要 Xcode 命令行工具、CocoaPods。默认生成 `dist/CrossTransfer-0.1.0-macos-local-test.dmg`，包含 arm64 / x86_64 App、native 库和 Applications 快捷方式。脚本检查可执行文件与 native 库架构匹配，重签嵌套代码并验证签名及镜像。

正式发布时使用自己的 Developer ID Application 证书与已经存入钥匙串的 notarytool profile：

```sh
CT_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
CT_NOTARY_PROFILE='your-profile' tools/package_macos.sh
```

此分支不配置或上传签名私钥。没有发布证书时生成的是本地测试包，不能当作已公证产品分发。Apple Development 证书不能替代 Developer ID。

### Flutter 3.47.5 的 macOS AOT 构建约束

当前 App 触发上游 [Flutter #191575](https://github.com/flutter/flutter/issues/191575)：`_window_macos.dart` 的 `_Rect` 类型在快照中仍被引用，但其 class ID 被裁掉，Release 编译器崩溃。直接 `flutter build macos --release` 在本机失败。

`tools/build_macos_app.py` 只接受 framework revision `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`，校验源文件 SHA-256 后，通过 macOS APFS 写时复制创建仓库 `build/` 下的独立 SDK。仅给 6 个内部 macOS FFI 类型增加 `@pragma('vm:entry-point')`，保留快照元数据；不启用实验窗口特性，也不改全局 SDK。构建前显式 `pub get --enforce-lockfile` 让 package_config 指向该副本，结束后恢复原 SDK 的解析路径。上游 SDK 更新必须重新验证并移除此临时处理，不能静默套用到其他版本。

该脚本已在本机生成 universal Release App。补丁作用于 Flutter 的 BSD 许可源码，原版权/许可保持不变；源码变更由脚本完整记录。原生传输库仍通过常规 native 构建脚本生成。

## Windows x64

需要 Visual Studio 2022 的 Desktop development with C++ 工作负载、Windows SDK、Flutter、xmake、NSIS 3；在 PowerShell 中运行：

```powershell
./tools/build_native.ps1
xmake build -y core_tests ct_cli
xmake run core_tests
Push-Location app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build windows --release
Pop-Location
./tools/package_windows.ps1 -MakeNsis "${env:ProgramFiles(x86)}/NSIS/makensis.exe"
```

生成 `dist/CrossTransfer-0.1.0-windows-x64-setup.exe`。安装范围为当前用户，无需管理员权限，目录默认 `%LOCALAPPDATA%\Programs\CrossTransfer`；安装器注册 `crosstransfer://`、开始菜单入口和卸载项，随包带上 MSVC CRT。已有窗口运行时，链接转发给已有实例。安装/卸载前须从托盘退出应用。卸载保留用户配置和接收文件。

`build_native.ps1 -Arch arm64` 可用于 native 移植检查，但本阶段的 Windows Flutter 安装器与 CI 验收目标为 x64。

Windows 原生目标及依赖统一使用动态 MSVC CRT（release 为 `/MD`，debug 为 `/MDd`），与 Flutter runner 保持一致。OpenSSL 仍静态链接，但本地配方会覆盖其 `no-shared` 默认的 `/MT` 编译选项，避免与其他依赖混用运行库。

## Linux（Ubuntu 24.04 / 对应 Debian 兼容环境）

```sh
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev \
  libsecret-1-dev libjsoncpp-dev \
  libstdc++-14-dev desktop-file-utils dpkg-dev
tools/build_native.sh linux
cd app
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build linux --release
cd ..
tools/package_linux.sh
sudo apt-get install ./dist/crosstransfer_*.deb
```

打包在目标架构的 Linux 上执行。支持 amd64 / arm64，使用 `dpkg-shlibdeps` 从可执行文件及所有插件计算系统依赖。程序放在 `/opt/crosstransfer`，共享库放在 `lib/`，安装 `.desktop` 和 `x-scheme-handler/crosstransfer` MIME 注册。GTK 使用单实例 GApplication，热启动链接送往原窗口。

`tools/linux_build_native.sh` 仅构建 native 库，不是完整 Linux 桌面构建。锁定的 cnativeapi 0.3.0 通过 D-Bus StatusNotifierItem 实现托盘，不需要 libayatana-appindicator。无通知服务/系统托盘的精简 Linux 环境可能不显示通知或托盘，真实桌面外观仍需人工验收。

## 验收

从 `app/` 运行共享库 ABI 冒烟测试（替换为实际平台路径）：

```sh
CT_NATIVE_LIB="$PWD/macos/native/libcrosstransfer_native.dylib" dart run tool/native_check.dart
```

该测试从公开头文件读取全部 `Ct*` 接口，验证符号、创建/销毁 core、异步 owned callback 以及配置读写。`tools/desktop_e2e.py --cli <ct_cli> --native <library>` 会自行启动使用独立端口的 Go 信令服务，检查 Dart FFI ⇄ CLI 双向传输，包括空文件、单块、多块、中文路径、空目录、SHA-256 和临时文件清理。

可额外传 `--app <installed executable>`，验证安装包内 native 库加载、首次链接接收、已有实例链接接收及文件完整性；Windows/Linux 首次通过 URI 直接启动，macOS 启动 App 后通过 Launch Services 投递。Linux 需图形环境，可用 `xvfb-run -a dbus-run-session -- python3 ...`。

`.github/workflows/desktop.yml` 在工作分支 push、PR 或手动触发时执行三平台构建、core/Dart 测试、FFI 传输、安装包生成。Windows 和 Linux 安装产物后验证 scheme 收件，macOS 从挂载的 DMG 运行并验证链接收件。Actions artifacts 保留安装包及校验文件；正式证书、公证、真实桌面托盘/通知权限和安装器交互外观不由无头 CI 代替。

App 自动使用原生库内的发行配置，不提供服务器设置入口。正式域名待定，缺少域名时商用原生构建会失败。

平台链接集成依据已锁定插件源码和上游说明：[app_links Windows](https://github.com/llfbandit/app_links/blob/main/doc/README_windows.md)、[app_links Linux](https://github.com/llfbandit/app_links/blob/main/doc/README_linux.md)。
