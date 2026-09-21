# 自托管服务

CrossTransfer 服务是单实例、内存状态的 Go 进程，提供 `/ws` 信令、取件码、TURN-UDP 和 WSS 中继。服务器不保存传输文件；第一版仍信任服务器转发的 DTLS 指纹。重启会清空分享、会话和服务器端续传令牌，因此升级应安排在活动传输结束后。

当前代码处于阶段 5 验收，正式下载包、生产域名和签名身份尚未配置。以下命令供运营者在自己控制的机器上部署，仓库中的 `example.com` 和文档 IP 必须替换。

## 本机开发

```sh
cd server
CT_LISTEN=127.0.0.1:8080 CT_TURN_PORT=0 go run ./cmd/ctserver
```

客户端设置主机 `127.0.0.1`、端口 `8080`、关闭 TLS。只在受控开发环境使用明文信令。正式网络使用 TLS；客户端校验证书链与 DNS/IP SAN，无法通过关闭主机名验证来绕过错误证书。

## 构建与配置

```sh
cd server
go test -race ./...
go vet ./...
CGO_ENABLED=0 go build -trimpath -o ctserver ./cmd/ctserver
cp .env.example .env
```

`.env` 是 Docker Compose 的环境文件；直接运行二进制时由服务管理器设置环境变量，或设置 `CT_CONFIG=/etc/ctserver/config.yaml`。配置优先级是环境变量 > YAML > 默认值。完整变量见 `server/.env.example` 和 `server/internal/config/config.go`。

推荐先选择一种 TLS 方式：

| 方式 | 配置 | 运维要求 |
| --- | --- | --- |
| 自带证书 | `CT_LISTEN=:443`、`CT_TLS_CERT`、`CT_TLS_KEY` | 证书文件含完整链，域名在 SAN 中；更新后重启服务加载新证书 |
| 内置 ACME | `CT_LISTEN=:443`、`CT_ACME_DOMAIN`、`CT_ACME_CACHE_DIR` | DNS 指向服务器，TCP 80/443 可达；由 autocert 申请/续期，缓存持久化 |
| 现有反向代理终止 TLS | 后端 `CT_LISTEN=127.0.0.1:8080` | 代理支持 WebSocket Upgrade；公开端证书由代理维护 |

ACME 与自带证书互斥。启用内置 ACME 表示运营者选择使用 Let's Encrypt，并同意其服务条款；程序会使用 `autocert.AcceptTOS`。本任务尚未对任何公网域名申请证书。证书私钥、ACME 缓存和 TURN secret 均不应提交到仓库。

## Linux Docker Compose

`server/compose.yaml` 使用 Linux host networking，以免为 TURN 中继范围逐端口映射。Docker Desktop 不等同于公网 Linux 主机的网络环境。

编辑 `.env`，至少填写：

```dotenv
CT_LISTEN=:443
CT_ACME_DOMAIN=transfer.example.com
CT_ACME_CACHE_DIR=/var/lib/ctserver/acme
CT_PUBLIC_IP=203.0.113.10
CT_TURN_PORT=3478
CT_TURN_PORT_RANGE=49152-65535
CT_TURN_SECRET=REPLACE_WITH_A_RANDOM_SECRET
CT_RELAY_RATE_LIMIT=4194304
CT_LOG_JSON=true
```

使用密码管理器或 `openssl rand -hex 32` 生成独立随机 secret。不要使用示例字符串。`CT_RELAY_RATE_LIMIT` 的单位为**每连接每秒字节**，示例为 4 MiB/s；它不限制 TURN 带宽，也不是总服务吞吐配额。

```sh
docker compose build
docker compose up -d
docker compose exec ctserver /ctserver -healthz
docker compose logs --tail=100 ctserver
```

镜像以 UID/GID 65532 运行，镜像内已准备具有相同所有者的 ACME 目录。全新命名卷继承该目录；已有卷或 bind mount 必须由运营者确认该 UID 可写，勿将整个目录设置为全员可写。自带证书需要额外的只读 bind mount，例如 `/etc/ctserver/certs:/etc/ctserver/certs:ro`。

允许入站 TCP 443（WSS）、TCP 80（内置 ACME HTTP-01）、UDP 3478 和设定的 UDP 中继端口范围。若禁用内置 TURN，设置 `CT_TURN_PORT=0`，只开放实际使用的端口。非 root 二进制直接绑定 80/443 时，需由服务管理器授予 `CAP_NET_BIND_SERVICE`，或由现有代理监听这些端口。

## TURN、代理和监控

- 内置 TURN 只支持 UDP；UDP 被封锁时客户端使用 WSS 中继。跨公网部署的 `CT_PUBLIC_IP` 必须是该主机实际可达的地址，端口范围同时在云安全组与主机防火墙放行。
- 外部 coturn：设置 `CT_EXTERNAL_TURN=turn:turn.example.com:3478?transport=udp`，两端使用相同的 `static-auth-secret` / `CT_TURN_SECRET`；这会关闭内置 TURN。配置外部 TURN 的用户/全局配额及禁止内网、回环等目标的权限策略。
- 当前内置 TURN 尚无完整公共服务配额与私网 peer 拒绝策略；对公网开放前应完成阶段 5 的这项加固，或使用配置好访问策略的外部 TURN。不要把 WSS 限速误当作 TURN 限速。
- 只有后端端口无法被公网直连、且可信代理**覆盖**客户端提供的转发头时，才设置 `CT_TRUST_PROXY=1`。否则保持关闭，避免绕过按 IP 的取件限速。
- `/healthz` 返回存活、版本、连接/分享/会话/TURN 数量。`ctserver -healthz` 使用相同的 YAML/环境设置，并为 ACME 提供正确的 SNI；此本机存活探针不验证服务端证书，不代表公网证书验收。
- `CT_METRICS=true` 开启 Prometheus 文本 `/metrics`。该路由没有独立鉴权，应由内部代理访问策略保护。默认关闭。
- 指标包括 `ct_peers`、`ct_sessions`、`ct_turn_allocations`、`ct_relay_bytes_total`、`ct_relay_dropped_total` 和 claim 成功/失败/限速计数。WSS 中继限速通过丢弃非可靠帧实现，客户端负责降速和重传。

## 下载与手机链接

`/r/<code>` 只接受规范化后的 10 位取件码，提供 `crosstransfer://r/<code>` 打开 App。浏览器不会直接接收文件。

配置 `CT_DOWNLOAD_URL=https://downloads.example.com/crosstransfer` 后页面显示下载入口；未配置时隐藏。URL 必须是 HTTPS，不得包含登录凭据。该设置不会替运营者生成、签名或上传安装包。

正式 Universal Link/App Link 先按 [iOS 构建](IOS_BUILD.md) 和 [Android 构建](ANDROID_BUILD.md) 运行对应身份配置工具，然后将生成的 `apple-app-site-association` 与 `assetlinks.json` 放到同一目录。配置 `CT_ASSOCIATION_DIR` 并将该目录只读挂载到容器；服务只公开这两个固定文件：

```text
https://transfer.example.com/.well-known/apple-app-site-association
https://transfer.example.com/.well-known/assetlinks.json
```

它们直接返回 JSON、无重定向。只部署实际使用的平台文件即可；非法 JSON 会使服务启动失败。文件内容在启动时读取，修改后需重启；移动系统的关联缓存可能延迟刷新。正式签名证书指纹、Apple Team ID、应用 ID 与域名必须与实际发布包一致。

## 升级与验收

1. 备份 `.env`/YAML、证书与 ACME 卷，保留上一个镜像标签。文件传输内容不在服务端，运行中的分享状态无法备份恢复。
2. 在独立测试端口运行新版本，检查 `/healthz`、可信 WSS、错误证书拒绝，以及真实两端 P2P/TURN/WSS 收发。
3. 等活动会话退出后更新镜像/二进制并重启；失败时回滚镜像与配置。重启前的取件码和会话不再有效，需要发送者重新创建分享。
4. 从公网检查证书完整链和 SAN、关联 JSON、取件页面和下载链接；从限制 UDP 的网络验证 WSS 回退。

本机证据与未完成项见 [阶段 5 记录](PHASE5_NOTES.md)。模拟器、回环与静态 16 KB 对齐检查不替代真实设备、真实网络或已签名分发验收。
