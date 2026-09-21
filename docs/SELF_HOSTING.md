# 自托管服务

服务端二进制内置 Go 依赖版权/许可文本，可运行 `ctserver -licenses` 查看；容器使用 `docker run --rm <镜像> -licenses`。清单覆盖 `go.mod` 中的 15 个直接/间接模块和 Go 运行时，`tools/check_go_notices.py` 与 CI 核对源码许可和模块版本。ISC 等既有许可的项目白名单解释仍见 `docs/LICENSE_AUDIT.md`。

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

Server CI 另保存 `ctserver-linux-amd64-arm64` artifact，其中包含两种 Linux 架构的 OCI 镜像归档与 SHA-256；它不是已发布的镜像地址。Dockerfile 在构建宿主上交叉编译静态 Go 二进制，无需模拟器参与编译。在仓库根目录可复现：

```sh
mkdir -p dist
docker buildx build --platform linux/amd64,linux/arm64 --provenance=false \
  --build-arg VERSION=local-test \
  --output type=oci,dest=dist/ctserver-linux-amd64-arm64.oci.tar \
  -t crosstransfer/ctserver:local-test server
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

使用密码管理器或 `openssl rand -hex 32` 生成独立随机 secret。不要使用示例字符串。`CT_RELAY_RATE_LIMIT` 的单位为**每连接每秒字节**，示例为 4 MiB/s；`CT_RELAY_GLOBAL_RATE_LIMIT` 单独约束全部 WSS 中继。TURN 使用自己的两项带宽设置，见下面配额表。

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
- 内置 TURN 默认拒绝私网、回环、CGNAT、链路本地、组播及特殊用途目标，当前中继只支持 IPv4。仅受控内网/回环测试可设置 `CT_TURN_ALLOW_PRIVATE_PEERS=true` 放行 RFC1918、回环和 CGNAT；链路本地（含常见云元数据地址）等仍拒绝。`tools/start_server.sh` 为本机开发默认启用此开关，公网部署不要使用该脚本的默认配置。
- 内置 TURN 的 socket 数量与有效载荷带宽有独立配额。目标 IP 过滤不能替代出站防火墙，也不能保护使用公网地址的内部服务。
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


## 资源与带宽配额

| 环境变量 | 默认值 | 作用 |
| --- | ---: | --- |
| CT_MAX_CONNECTIONS | 1024 | 同时占用的信令 WebSocket 名额，含正在升级的请求 |
| CT_MAX_CONNECTIONS_PER_IP | 32 | 单个客户端 IP 的连接名额；需按共享 NAT 用户规模调整 |
| CT_MAX_SESSIONS | 4096 | 全部会话，含等待接收端续传的会话 |
| CT_MAX_SESSIONS_PER_PEER | 64 | 每个 peer 参与/持有的会话，发送端离线接收者仍占名额 |
| CT_TURN_MAX_ALLOCATIONS | 512 | 内嵌 TURN 实际 relay socket 数；创建与检查在同一锁内 |
| CT_RELAY_RATE_LIMIT | 8388608 | 单连接 WSS 中继 payload 字节/秒 |
| CT_RELAY_GLOBAL_RATE_LIMIT | 67108864 | 所有 WSS 中继 payload 字节/秒 |
| CT_TURN_RATE_LIMIT | 8388608 | 每 allocation 收发合计 payload 字节/秒 |
| CT_TURN_GLOBAL_RATE_LIMIT | 67108864 | 所有 TURN relay socket 收发合计 payload 字节/秒 |

数量必须为正；带宽值为 0 表示运营者显式关闭该限速，负值启动失败。令牌桶突发允许一秒流量，至少 64 KiB，以容纳完整 UDP 报文。TURN 从发送端 allocation 到接收端 allocation 的同一数据会在两个 relay socket 各计一次；计量不包含 IP/UDP、STUN 等网络开销，不能直接当作云厂商账单字节。

连接满时返回 HTTP 503 和 `Retry-After: 5`，还未建立 WebSocket；升级失败和断开释放连接名额。新会话满时返回 `server_busy`，once 码不消耗；原会话持有名额，接收端可用 token 恢复，关闭分享或过期才彻底释放。每连接分享数保持最多 16。WSS 发送队列同时限制 512 帧和 4 MiB：中继帧满时丢弃，可靠控制消息无法排队则关闭慢连接。

TURN 满时返回分配失败，实际 socket 关闭才释放配额，重复 Close 不会重复释放。客户端未显式发 Refresh(0) 时，其 allocation 可能保留到 TURN lifetime 结束，因此并发预算需要包含刚离线的 allocation。全局和单 allocation 限速丢弃报文，现有 KCP/SACK 负责恢复；WSS 限速同理。

启用受网络限制的 `/metrics` 后，可观察 `ct_connections_limited_total`、`ct_sessions_limited_total`、`ct_turn_relay_sockets`、`ct_turn_capacity_rejected_total`、`ct_turn_payload_bytes_total`、`ct_turn_rate_dropped_total`、`ct_relay_dropped_total` 与 `ct_relay_queue_dropped_total`。按实际机器内存、网络出口和共享 NAT 用户数调低或调高默认容量；外部 coturn 不受本进程 TURN 配额控制。

回归命令（使用隔离的临时 CA、服务和状态目录）：

```sh
python3 tools/run_transfer_load.py --cli build/macosx/arm64/release/ct_cli --receivers 4 --mib 8 --cases turn-limited relay-limited --output dist/limited-load.json
```

此命令检查 SHA-256、实际数据路径、配额确实丢弃过报文以及 peer/share/session 回收。它是本机功能回归，公网部署仍需真实链路与长期容量观察。
