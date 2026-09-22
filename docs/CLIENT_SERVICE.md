# 客户端服务配置（内部发行说明）

CrossTransfer 的连接服务由发行方部署和运维，用户只需发送或接收文件。客户端不提供服务器地址、端口、TLS、分享域名、TURN 或中继配置，也不要求用户部署服务。

## 商用构建

所有平台共用原生 core 内的发行配置。默认是商用模式，必须在构建时指定正式域名；缺少域名会中止原生构建。域名仅填写主机名，不带协议、端口或路径。信令固定使用 `wss://<域名>:443/ws`，传输路径自动选择，SRTP 始终开启。

```sh
CT_SERVICE_HOST=transfer.example.com tools/build_native.sh
# 可选：由发行方指定分享链接域名；留空使用 crosstransfer:// 链接。
CT_SERVICE_HOST=transfer.example.com CT_LINK_HOST=share.example.com tools/build_android_native.sh
CT_SERVICE_HOST=transfer.example.com tools/build_ios_native.sh
```

上述域名仅是语法示例，不是可用服务。Windows PowerShell 使用 `$env:CT_SERVICE_HOST` 和 `$env:CT_LINK_HOST` 后执行 `tools/build_native.ps1`。直接使用 xmake 时：

```sh
xmake f -m release --ct_developer=n --ct_service_host=transfer.example.com --ct_link_host=share.example.com -y
xmake build -y
```

脚本每次显式传入模式与域名，避免复用上次联调配置。更新域名必须重新构建对应平台原生库并重新打包 App；不能只重新构建 Flutter。正式域名目前待定，尚不能产出可上线的服务配置。

商用 core 加载旧 `config.json` 时忽略连接参数，保存时清除这些字段；`CtQuery` 和配置事件仅提供 `service_available` 状态。运行时 `CtUpdateConfig` 拒绝连接参数修改，但保存目录、分享模式和有效期等偏好设置仍可正常更新。CLI 商用构建也不接受连接参数。

## 内部开发与自动化验收

开发能力必须显式启用，与编译优化模式（debug/release）无关：

```sh
CT_DEVELOPER_MODE=y tools/build_native.sh
xmake f -m release --ct_developer=y -y
xmake build -y core_tests ct_cli
```

开发构建默认连接本机 `127.0.0.1:8080`，允许内部 CLI、FFI 与测试配置覆盖地址、TLS 和传输策略。App 设置页在开发构建中也不显示这些参数。现有桌面、Android、iOS CI 显式使用开发模式以运行隔离的回环服务；其产物只用于内部验收，不得作为商用发行包。发行环境必须取消 `CT_DEVELOPER_MODE` 或设为 `n`，重新构建原生库。

域名是连接目标，不是秘密凭据。此机制管理产品配置与展示，不试图通过隐藏地址代替服务端认证或访问控制。

商用策略的 ABI 回归可对 `--ct_developer=n --ct_service_host=service-policy.invalid` 的测试库运行 `python3 tools/check_client_service.py <native-library>`，覆盖旧配置迁移、查询/持久化脱敏、运行时拒绝覆盖、偏好设置保存与重启。`.invalid` 域名仅用于离线验证，不可作为发行配置。
