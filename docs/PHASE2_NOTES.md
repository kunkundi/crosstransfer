# 阶段 2 实施记录（2026-09-21，macOS 部分）

## 环境

- Flutter 3.47.5 stable（Dart 3.13.4），Homebrew cask 安装；CocoaPods 1.x 由 Homebrew 安装。
- `flutter doctor`：Xcode 26.6 与 macOS 工具链就绪；Android SDK 未装（阶段 4 再装）。

## 交付

| 项 | 状态 |
| --- | --- |
| `crosstransfer_native` 共享库（`-force_load` 整体链接 core + minirtc） | macOS arm64 验证通过，15 个 `Ct*` 符号导出，只依赖系统库；`install_name` 为 `@rpath/`；`tools/build_native.sh` 一键构建并复制到 `app/<plat>/native/` |
| `CtSetEventCallbackOwned`（仅共享库导出） | 新增：事件以 `malloc` 副本投递，供 Dart `NativeCallable.listener` 异步消费 |
| `transfer_state` / `transfer_progress` 事件增加 `share_id` | 发送端多接收者时 UI 据此把传输归到对应分享卡片 |
| `app/`（Flutter，macOS / Windows / Linux 目标） | `flutter create` 骨架 + 依赖；`flutter analyze` 零问题；`flutter test` 6 用例通过 |
| `app/ffigen.yaml` → `lib/ffi/ct_bindings.g.dart` | ffigen 22 生成，只包含 `Ct*` |
| `lib/ffi/core_client.dart` | `CoreClient`：打开动态库、`Ct*` 封装、事件 `Stream<Map>` |
| `lib/state/` | Riverpod 3：`CoreStateNotifier` 聚合 `signal_state` / `share_state` / `receive_state` / `transfer_*` / `config` / `error`；`ShareInfo` / `ReceiveInfo` / `TransferInfo` / `CoreConfig` 模型；语言与导航状态；`ui.json` 存 UI 偏好 |
| 页面 | 发送（拖放 / 选文件 / 选文件夹 → 卡片：二维码、链接、取件码、倒计时、复制、关闭、进度）；接收（粘贴链接或码、保存目录、卡片：进度 / 暂停 / 续传 / 取消 / 打开目录、错误码本地化）；设置（保存目录、语言、服务器、TLS、链接域名、TURN / 中继模式、UPnP、默认分享模式与 ttl、日志级别、关于） |
| 平台集成 | 托盘（`tray_manager` 0.7 的 `legacy.dart` 兼容层）+ 关窗隐藏（`window_manager` `setPreventClose`）；`crosstransfer://` scheme（`app_links` + `Info.plist` `CFBundleURLTypes`）；桌面通知（`flutter_local_notifications`）；Dock 点击重开窗口（`AppDelegate.swift`） |
| macOS 打包 | `Podfile` 引入 `macos/native/crosstransfer_native.podspec`（`vendored_libraries`），dylib 进 `Contents/Frameworks/` 并随 app 签名；`flutter build macos --release` 通过（app 54 MB） |
| Linux / Windows 骨架 | `CMakeLists.txt` 已加 `native/` 下共享库的 install 规则；`tools/linux_build_native.sh` 在 Ubuntu 24.04 容器内构建通过（arm64 `.so`）；Windows 未编译，Linux 桌面未验证 |
| macOS universal | `tools/build_native.sh macosx universal`：arm64 + x86_64 各自构建后 `lipo` 合并，`minirtc/thirdparty/openssl3/` 为本地覆盖配方 |
| 中英文 | `lib/i18n/strings.dart` 简单键值表，运行时切换 |

## 实测（本机，本地 `ctserver`）

| 场景 | 结果 |
| --- | --- |
| `tool/ffi_smoke.dart share`（纯 Dart 经 FFI）→ `ct_cli receive` 3 MB | 通过，SHA-256 一致 |
| App 经 `open crosstransfer://r/<code>` 接收 `ct_cli share` 的目录（2 文件 7.6 MiB） | 通过，链接自动切到接收页并填入码，回车后完成，两文件 SHA-256 一致；“打开目录”可用 |
| App 选文件夹分享（2 文件 19.1 MiB）→ `ct_cli receive` | 通过，卡片显示二维码 / 链接 / 取件码 / 倒计时，完成后状态“已完成”，SHA-256 一致 |
| 过期 / 不存在的码 | 卡片显示“失败 · 取件码不存在”，不再提供无意义的“续传”按钮 |
| 关窗 → 进程存活、窗口隐藏 → `open crosstransfer://…` 再拉起窗口 | 通过 |
| 托盘图标 | 菜单栏显示（模板图标） |

## 与规划的偏差 / 决定

- **macOS 最低版本 12.0**：Flutter 3.47 模板与多数插件（`file_picker_darwin` 等）要求 12.0，native 库随之以 `--target_minver=12.0` 构建（`tools/build_native.sh` 已带）。规划写的 10.15 不再可行。
- **不用 App Sandbox**：P2P 需要任意 UDP 端口与用户任意目录读写，沙箱下 `file_picker` / 拖放只给安全作用域书签、目录写入受限；关闭沙箱意味着不能上 Mac App Store，走公证分发（dmg）。仍保留 `files.user-selected.read-write` entitlement，因为 `file_picker_darwin` 2.x 无论是否沙箱都检查它。
- **`file_picker` 13.x API**：`pickFiles()` 返回 `List<PlatformFile>`，默认多选；`getDirectoryPath()` 选目录。
- **`tray_manager` 0.7** 改成 nativeapi 后端，0.5 式 API 在 `package:tray_manager/legacy.dart`，已标 deprecated；先用兼容层，后续迁到 `TrayIcon` API。
- **ffigen 22** 仍支持 `ffigen.yaml`（`dart run ffigen --config ffigen.yaml`），但 `CtSetEventCallback` 的同步语义与 `NativeCallable.listener` 的异步投递不兼容，因此加 `CtSetEventCallbackOwned`。
- **首次运行默认值**：`Core` 创建时会把空的 `save_dir` 填成 `<data_dir>/received` 并持久化，所以 App 首启（无 `config.json`）时把默认保存目录（`~/Downloads/CrossTransfer`）与开发服务器（debug 构建 `127.0.0.1:8080`）直接放进 `CtCreate` 的配置，而不是事后 `CtUpdateConfig`。
- **data_dir**：`getApplicationSupportDirectory()`（macOS `~/Library/Application Support/com.crosstransfer.crosstransfer`）；`CT_DATA_DIR` 环境变量可覆盖，`CT_NATIVE_LIB` 可指定动态库路径（开发 / 测试用）。
- **接收卡片“续传”按钮**：只在 `interrupted`，或 `failed` 且有 `resume_token` / 非永久错误（`code_not_found` / `code_expired` / `share_closed` / `user`）时显示。

## 已知问题 / 后续

- `share_state` 事件不含分享的本地路径，UI 在 `createShare` 时自行记下 `paths` 用于卡片标题；重启后从 `CtQuery` 恢复的分享只显示取件码。
- 发送端 `transfer_progress` 的 `rate_bps` 在本机回环短传输里常为 0（1 s 窗口尚未填满），UI 只在 > 0 时显示速率；真实网络下待观察。
- 拖放（`desktop_drop`）与通知（`flutter_local_notifications`）只做了代码路径，未自动化验证；通知在 macOS 首次运行弹权限框（已观察到）。
- 语言切换后已渲染页面即时更新，但托盘菜单需重建（已处理），系统通知标题用当时语言。
- Windows：`crosstransfer_native` 的 MSVC 配方（`/WHOLEARCHIVE`、`CT_BUILDING_SHARED`）与 `app/windows` 的 dll 安装规则已写，未在 Windows 上编译；`minirtc` 本身也未在 Windows 实测（阶段 0 遗留）。
- Linux：`tools/linux_build_native.sh` 在 Ubuntu 24.04 容器里构建通过（Docker Desktop 首次尝试卡在包下载并报 `meta.db: read-only file system`，重启 Docker 后正常）。容器是 arm64，产物 `libcrosstransfer_native.so` 为 aarch64，16 个 `Ct*` 符号导出，只依赖 glibc / libstdc++；x86_64 需在 x86_64 宿主或 `--platform linux/amd64` 容器里跑同一脚本。GCC 暴露出 core 里 23 个文件用了 `uint8_t` 等却没显式 `#include <cstdint>`（clang 隐式带入），已补齐。GTK 应用需在 Linux 桌面验证托盘（`tray_manager` 依赖 `libayatana-appindicator`）与 `app_links` 的 scheme 注册（`.desktop` 文件 `MimeType=x-scheme-handler/crosstransfer`）。
- macOS x86_64 交叉构建：xmake-repo 的 `openssl3` 配方在 macosx 上用 `./config` 让 OpenSSL 自猜目标（按宿主 CPU 选 `darwin64-arm64`），与 xmake 传入的 `-target x86_64` 冲突报 `unsupported ARM architecture`。已在 `minirtc/thirdparty/openssl3/` 放本地覆盖配方，macOS 上改为显式 `./Configure darwin64-<arch>-cc`。`tools/build_native.sh macosx universal` 构建两个 arch 并 `lipo` 合并。
- 打包（dmg / NSIS / deb）与签名、公证尚未做。
- `flutter build macos` 会提示所有插件已是 Swift Package，但项目仍用 CocoaPods 集成 `crosstransfer_native`；等 Flutter 的 SwiftPM 支持能引入本地二进制 target 后再迁移。
