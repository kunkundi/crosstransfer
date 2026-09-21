# 依赖许可审计（进行中）

审计以实际锁文件、构建产物与上游文本为依据，不以顶层插件声明代替传递依赖检查。阶段 5 尚未完成全量分发清单。

## 已核对的边界

`docs/PLAN.md` 目前写明“依赖仅 MPL / BSD / Boost / Apache / MIT”。移除 Android ML Kit 后，仍有以下**既有依赖**超出这些 SPDX 名称。它们与 ML Kit 的额外 API 条款不同，属于宽松许可或 BSD 风格许可；是否将它们明确纳入项目白名单，待所有者明确规则意图。

| 既有组件 | 实际许可 | 证据与处理义务 |
| --- | --- | --- |
| 服务端 coder/websocket v1.8.15 | ISC | [锁定版本文本](https://github.com/coder/websocket/blob/v1.8.15/LICENSE.txt)；保留版权和许可声明 |
| Flutter 引擎 ICU 数据/代码 | Unicode-3.0 / Unicode-DFS / ICU 及所带数据声明 | 实际 APK `flutter_assets/NOTICES.Z`，组件 `icu`；[Unicode 官方文本](https://www.unicode.org/license.txt)；保留对应版本的版权和声明 |
| Flutter 引擎 zlib | Zlib | 实际 NOTICES 中 `zlib`；[官方许可](https://zlib.net/zlib_license.html)；保留声明、修改不得误表来源 |
| Flutter 引擎 libpng | Libpng / libpng-2.0 | 实际 NOTICES 中 `libpng`；保留原版权与许可文本 |
| Flutter 引擎 FreeType | FTL（BSD 风格，选择此许可） | [官方双许可说明](https://freetype.org/license.html)；保留署名声明，不选择 GPL 路径 |
| Flutter 引擎 libjpeg-turbo | IJG / BSD-3 / Zlib | 实际 NOTICES 中该组件的完整许可说明；保留版权、JPEG 作者致谢和免责声明 |

实际产物为 Flutter 3.47.5 构建的 Android Release APK（2026-09-22）。其许可文件还包含 Apache-2.0 的 LLVM 例外中的 GPL 兼容说明，**不能因出现“GPL”字符串就判定引入 GPL 依赖**；需按每个组件选择的实际许可证判断。

## 已完成的整改

- 原生 OpenSSL 升级至 3.5.8 LTS，Apache-2.0，固定官方归档校验和。
- 删除 `mobile_scanner` 与 Android ML Kit 传递依赖；原生 iOS AVFoundation、Android ZXing Android Embedded 4.3.0 / Core 3.4.1（Apache-2.0）替代。
- Android Gradle `releaseRuntimeClasspath` 确认没有 `mlkit` / `play-services`；最终 APK 的原生库从 24 个降至 15 个。
- ZXing 完整文本保存在 `docs/licenses/`。Flutter/Dart 自身生成的 NOTICES 包含其包和引擎声明；仍需接入 App 内入口与补充原生/Android/服务端完整清单。

## 待完成

- 明确以上既有宽松许可证的白名单解释并更新 PLAN。
- 锁定 native、Go、pub、Gradle 与 Apple 传递依赖清单，包含源码版本、来源、许可证和文本校验和；区分构建/测试工具与运行时。
- MPL-2.0 libjuice 即使未修改，分发二进制也需要告知取得对应源代码的方式；当前根 NOTICE 中“仅修改时”的描述不完整，需补齐。
- App 法律页面与所有分发物携带完整版权/许可文本及必要源码信息；设置 CI 防止锁文件更新后清单失配。
