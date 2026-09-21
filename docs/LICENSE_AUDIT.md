# 依赖许可审计

本清单按实际锁文件、依赖源码、构建图与产物核对。它记录项目采用的许可与分发方式；不以顶层插件声明代替传递依赖检查。Windows/Linux 最终产物仍需在 CI 恢复后验收，不能把本机检查视为全平台发布批准。

## 已授权的边界（2026-09-22）

所有者已明确允许既有 ISC、Unicode/ICU、Zlib、libpng、FTL/IJG 和 public-domain，补充 PLAN 原有的 MPL/BSD/Boost/Apache/MIT 范围。唯一 LGPL 例外为 Linux 界面动态链接系统提供、未修改、不随 App 打包的 GTK/GLib；此例外不适用于 ICE、移动端或随产品静态链接/复制的 LGPL 库，也不包括 Android GPL＋Classpath 运行库。

| 既有组件 | 实际许可 | 证据与分发方式 |
| --- | --- | --- |
| coder/websocket v1.8.15 | ISC | [锁定版本原文](https://github.com/coder/websocket/blob/v1.8.15/LICENSE.txt)，随 `ctserver -licenses` 输出 |
| Flutter 引擎 ICU | Unicode-3.0 / Unicode-DFS / ICU 及所带数据声明 | 引擎 `sky_engine/LICENSE` 与实际包中 `NOTICES.Z`，完整保留 |
| Flutter 引擎 zlib / libpng | Zlib / libpng | 实际包中 `NOTICES.Z`，完整保留 |
| Flutter 引擎 FreeType | FTL（选择此许可） | [官方双许可说明](https://freetype.org/license.html)，保留署名，未选择 GPL 路径 |
| Flutter 引擎 libjpeg-turbo | IJG / BSD-3 / Zlib | 实际 NOTICES 中的版权、JPEG 作者致谢与免责声明 |
| websocketpp 所带 base64/MD5 等 | BSD-3 / MIT / Zlib | 官方 COPYING 完整原文在 `websocketpp.txt` |
| libjuice 所带 picohash | public-domain dedication | `src/picohash.h` 原文，另附 `picohash.txt` |
| Linux 系统 GTK/GLib | LGPL，限定系统动态链接 | Flutter runner 使用 pkg-config `gtk+-3.0`；安装器由 dpkg-shlibdeps 生成系统依赖，不复制这些系统库 |

LLVM 例外文本提及 GPL 兼容性、FreeType 文本列出双许可，都不能仅凭“GPL”字符串就判定采用 GPL；应按组件与实际选定许可判断。操作系统框架和开发工具运行时单独按平台 SDK/再分发条款使用，不把它们冒记成 MIT/BSD 的第三方开源包。

## 清单与完整文本

- `docs/licenses/native_manifest.json`：固定版本原生依赖及补充声明的来源、上游归档哈希、文本哈希、平台、源码归档。原文镜像到 `app/assets/legal/`，包括 OpenSSL、asio、KCP、miniupnpc、libsrtp、spdlog 及其 fmt、JSON、websocketpp、WebRTC LICENSE/PATENTS、libjuice/picohash、ZXing 和 Android 运行库。
- `docs/licenses/pub_manifest.json`：Flutter 3.47.5 / engine 固定 revision、103 项主依赖声明闭包及其许可文本/包归档哈希。闭包包含各平台替代实现、build hooks 和上游依赖的测试辅助包，**不代表 103 项均在每个平台执行**。具体包和引擎完整许可由 Flutter 生成 `NOTICES.Z` 并显示在 LicenseRegistry 中。
- `docs/licenses/android-runtime-modules.txt`、`android_manifest.json`：Release Maven 解析图 68 个坐标，包括 POM/父 POM、实际 AAR/JAR 与内嵌 NOTICE/LICENSE 的 SHA-256。除 4 个由 Flutter engine NOTICES 覆盖的坐标，其余核对为 Apache-2.0；完整文本与保留的内嵌声明合并到 `android-runtime.txt`。
- `docs/licenses/go_manifest.json`、`server/internal/legal/NOTICE.txt`：固定 Go 模块、全部 15 个直接/间接模块与 Go 运行时的来源、版本和原文；静态嵌入单二进制，通过 `ctserver -licenses` 离线读取。
- Apple 的 Podfile.lock 仅含项目原生库、Flutter，以及 iOS 的 BSD-3-Clause `open_filex`；其余插件通过 pub 固定版本的本地 Swift Package 集成，所检查的 Package.swift 没有另行拉取远程包。
- Windows 插件直接使用系统 Win32/WinRT；`cnativeapi` 的可选 WinUI 3 默认关闭，未启用外部 WindowsAppSDK 包。GoogleTest 仅在插件测试选项开启时使用，不属于 App 分发。MSVC CRT 通过 Visual Studio 的官方 Redist 目录按平台再分发条款随包提供，实际 Windows 安装包及 DLL 清单待 CI 验证。

原生 test-only doctest、ffigen、分析器、编译器、Gradle、CMake、xmake 与 Go 工具本身不当作产品运行库。Linux 的 GTK/GLib 和平台 C/C++ 运行库来自操作系统，最终动态依赖以发行版生成的包依赖为准。

Flutter SDK 的 `flutter`、`flutter_test`、`flutter_web_plugins` BSD 文本存在官方平台差异：Windows 3.47.5 SDK 归档使用 CRLF，其他平台使用 LF。已从官方 Windows 归档读取并逐字核对，差异仅为换行。`license_sha256` 保留 LF 原文哈希 `a598db94…`，另记录 `license_sha256_windows_crlf` 的原始字节哈希 `a3a9fd82…`；门禁仅接受这两种完整形式。混合换行或文字改动仍被拒绝，其他依赖（含 engine NOTICES）继续核对唯一原始哈希，不改写 SDK 文件。

## MPL 对应源码

设置 → 开源许可证可离线查看完整许可并导出以下完整源码：

| 归档 | 内容 | SHA-256 |
| --- | --- | --- |
| libjuice-1.7.2-ct1.tar.gz | 官方完整源码、ct1 relay-only 补丁及修改说明 | `916a4d3cf32cd8ab4fdca2f7a6b39d94b90e1915471030850abaa26833e11c25` |
| dbus-0.7.15.tar.gz | 未修改的官方 pub 源码包 | `a48d5da28e89bd02196e80d81ed8d7954923d00a0f4a68cc20b575038f023383` |
| gtk-2.2.0.tar.gz | 未修改的 Dart gtk pub 源码包；与系统 GTK 分开 | `4ff85b2a16724029dd9e5bbb5a94b6918f9973f74ba571c949d2002801879cf5` |

源码在 `app/assets/legal/`，均附原 MPL-2.0 文本。CrossTransfer 的专有许可不限制接收者对覆盖源码的 MPL 权利。即使未修改的编译后 MPL 组件也需告知对应源码取得方式，参见 [Mozilla FAQ Q8/Q10](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)。

## 已移除的运行依赖

- Android ML Kit / Play Services 及聚合扫码插件：替换为 iOS 系统 AVFoundation、Android ZXing Embedded 4.3.0 / Core 3.4.1。
- `flutter_local_notifications` 聚合插件与 `desugar_jdk_libs 2.1.4`（GPL-2.0 with Classpath Exception）：Android 使用系统 NotificationManager，Apple 使用系统 UserNotifications；Linux/Windows 保留已审计的 BSD-3-Clause 平台插件。
- ICE 路径的 libnice、glib、gupnp 及旧音视频依赖仍完全移除，不利用 Linux 界面系统库例外重新引入。

## 防止清单漂移

1. `tools/check_legal_assets.py` 离线核对镜像文本、源码哈希及已审计依赖输入；依赖输入改变需重新审计，不能仅更新校验和绕过。
2. `tools/check_pub_notices.py` 根据 pub 的实际声明图与缓存文本重算清单，并将 dbus/gtk 源码逐文件与已解析的代码比较。`--write` 只刷新待审阅证据，不扩大许可范围。
3. `tools/check_libjuice_source.py` 对固定哈希上游归档应用本仓库补丁，逐文件比对 ct1 完整源码；`tools/check_go_notices.py` 比对实际 Go 模块和嵌入原文。
4. Gradle `:app:verifyRuntimeLicenses` 要求 Release 解析图与已审计坐标完全一致，并拒绝 desugaring、ML Kit、Play Services。`tools/check_android_notices.py` 重算 Maven 证据。
5. Android 最终 APK 检查原生对齐、签名、源码/许可资产，以及 DEX 不含 `j$`、ML Kit 和已移除通知插件的类。桌面/iOS 产物检查 Flutter notices 与补充资产逐字节一致；Linux 打包另检查 GTK/GLib 只动态解析到包外的系统库。

CI 已接入这些门禁，账单阻塞已解除。macOS/Linux 的最终安装包法律资产与冷/热链接收件均已通过；Windows 矩阵继续验收。真实桌面的托盘、通知与安装器交互外观仍需人工验收。
