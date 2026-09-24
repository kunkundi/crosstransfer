# 信令协议 v1（实现说明）

服务端实现：`server/internal/signal`；客户端实现：`minirtc/src/pc/peer_connection.cpp`。
规范条目见 `docs/PLAN.md` 第三部分，本文记录实现层面的确定值。

## 连接

- 端点 `/ws`，子协议 `ct-signal-v1`（可选）。文本帧为 JSON，二进制帧为中继帧。
- 每条消息 `{"type":"...","id":<int64,可选>}`；带 `id` 的请求得到同 `id` 的回复（`ok`、专用回复或 `error`）。
- 服务端每 `heartbeat_sec` 发 WebSocket ping，两次心跳无响应即断开；客户端也可发 `{"type":"ping"}` 得到 `pong{server_time}`。
- 连接断开即清理该连接持有的 share 与其作为接收端的 session（session 保留至 share 过期以便续传）。

## 消息

| 方向 | type | 字段 | 回复 |
| --- | --- | --- | --- |
| C→S | `hello` | `app`, `version`, `platform`, `proto`=1, `notifications`(可选 bool) | `welcome{peer_id, ice_servers[], heartbeat_sec, server_time}` |
| C→S | `create_share` | `mode`("once"/"open"), `ttl_sec`, `meta`(≤16 KiB JSON) | `share_created{share_id, code, code_display, expires_at, mode}` |
| C→S | `close_share` | `share_id` | `ok`；已配对接收端收到 `session_end{reason:"share_closed"}` |
| C→S | `claim` | `code` 或 `resume_token` | 成功：双方 `session_start`（接收端的带请求 `id`）；失败：`error{code}` |
| C↔S | `signal` | `session_id`, `to`(可选), `payload` | 转发为 `signal{session_id, from, to, payload}`；带 `id` 时回 `ok` |
| C→S | `leave` | `session_id` | `ok`；对端 `session_end{reason:"peer_left"}` |
| S→C | `share_closed` | `share_id`, `reason` | share 因过期/服务端关闭而结束（主动 `close_share` 不回显） |
| S→C | `session_end` | `session_id`, `reason` | `peer_left` / `peer_offline` / `share_closed` / `share_expired` / `server_shutdown` |

`session_start` 字段：`session_id`(16 hex)、`share_id`、`role`("sender"/"receiver")、`remote_peer_id`、`ice_servers[]`、`resume_token`(32 hex)、`resumed`、`meta`(仅接收端)。

`ice_servers[]` 与 WebRTC `RTCIceServer` 同形：`{urls[], username?, credential?, expires_at?}`；TURN 凭据为 coturn REST 算法（`<expiry>:<peer_id>` / base64(HMAC-SHA1)），有效期 `CT_TURN_CRED_TTL`。

## 运营通知扩展

支持通知的客户端在 `hello` 中设置 `notifications: true`。服务端在 `welcome` 之后发送完整有效通知列表，并在发布或撤回后发送新快照；未声明该能力的旧客户端不会收到扩展消息，协议版本仍为 1。

```json
{"type":"notifications","items":[{"id":"0123456789abcdef0123456789abcdef","title":"服务维护","body":"维护详情","level":"maintenance","created_at":1780000000}]}
```

`id` 是服务端随机生成的 32 位十六进制 ID；`created_at` 为 Unix 秒；`level` 为 `info` / `important` / `maintenance`。列表按发布时间从新到旧，最多 50 条，空列表表示清空；客户端以此快照替换本地缓存，并按 ID 保存已读/已提醒状态。正文和标题分别最多 2000/120 个 Unicode 码点，完整消息小于 1 MiB。所有 peer 的入队顺序与持久化提交顺序一致，hello 与更新并发时也不会回退到旧快照。

此扩展不包含取件码、身份或传输数据，不开放客户端发通知能力。管理接口和存储设置见 SELF_HOSTING「通知管理后台」。MiniRTC 的 `on_notifications` 回调将借用的 JSON 交给 core；core 发送 `notifications` 事件并在 `CtQuery(all)` 的 `notifications` 字段中保留快照（首次同步前为 null），供 Flutter 启动时补取。

## 错误码

`bad_request`、`hello_required`、`unsupported_proto`、`code_not_found`、`code_expired`、`share_busy`、`rate_limited`、`share_not_found`、`session_invalid`、`peer_offline`、`too_many_shares`、`internal`。

`claim` 失败一律附带常量延迟（`CT_CLAIM_FAIL_DELAY`），并按 IP 与全局令牌桶限速。

## `signal.payload`

由客户端定义，服务端不解析。当前 MiniRTC 使用：

- `{"sdp":"...","kind":"offer"|"answer"}`：接收端先发 offer。
- `{"candidate":"a=candidate:..."}`：trickle ICE 候选。
- `{"candidates_done":true}`：候选收集结束。
- `{"relay":true}`：请求对端切换到 WSS 中继。

保留字段 `auth` 供 SPAKE2 升级。

## 中继帧（二进制）

```
magic "CR" (2) | version 0x01 (1) | flags 0 (1) | session_id ASCII (16) | payload
```

服务端只校验头部与会话成员关系，按连接令牌桶限速（`CT_RELAY_RATE_LIMIT`，0 为不限），超出即丢弃；未知 session 的帧静默丢弃。发送队列满时丢弃中继帧而不断开连接（控制消息仍会断开）。

## SDP（客户端间约定）

MiniRTC 双方交换一段极简 SDP：`m=application 9 UDP/DTLS/RTP/SAVPF 120 121`，含 libjuice 的 `a=ice-ufrag/ice-pwd/ice-options`、`a=fingerprint:sha-256`、`a=setup`，以及每条数据流一行

```
a=x-data-stream:<name> <ssrc> <reliable 0|1>
```

流名与可靠性两端必须一致。接收端（offerer）是 DTLS client。


### 服务容量拒绝

`/ws` 在全局/每 IP 连接数达到配置上限时返回 HTTP 503 与 `Retry-After: 5`。尚未完成 WebSocket 升级，不会发 JSON welcome。会话达到全局或每 peer 上限时，claim 返回 `error`，`code: "server_busy"`；该失败不消费 once 码，也不创建 resume token。已持有名额的暂停会话仍可由有空余 peer 会话名额的接收端续传。具体默认值与 payload 限速见 SELF_HOSTING 的资源配额表。
