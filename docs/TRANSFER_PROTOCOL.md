# 传输协议 v1（core 之间）

两端 `core/` 在一条 MiniRTC session 上使用三条数据流：

| 流名 | MiniRTC 类型 | 内容 |
| --- | --- | --- |
| `ctrl` | 可靠（KCP，窗口 1024） | JSON 控制消息，见下 |
| `data` | 非可靠 | 数据块，一块一报文 |
| `sack` | 非可靠 | 接收端选择性确认，一份一报文 |

所有多字节整数为大端。常量定义在 `core/src/transfer/protocol.h`。

## ctrl 分帧

KCP 单条消息最多 127 个分片，因此 JSON 文档按 `kCtrlChunk` = 16 KiB 切块，每块前置 1 字节标志（`0x00` 未完，`0x01` 末块），流有序所以同一消息的块连续。重组上限 16 MiB。

## ctrl 消息

固定由**接收端发 ICE offer**（信令层），但**文件传输由发送端发起**：

| 方向 | type | 字段 | 说明 |
| --- | --- | --- | --- |
| S→R | `offer` | `manifest` | 传输连通后立即发送 |
| R→S | `accept` | `files[]`：`{index, verified:true}` 或 `{index, have:[[start,len],…]}` | 续传时报告已校验文件与已有块游程 |
| S→R | `file_done` | `index`, `sha256` | 该文件 Sweep 完成（哈希在读文件时计算） |
| R→S | `file_ok` | `index` | 位图填满且 SHA-256 一致，已改名到位 |
| R→S | `file_bad` | `index`, `reason` | 校验失败；接收端已清空该文件位图，发送端清掉 accept 里的已有块并整文件重发 |
| S→R | `transfer_done` | | 所有文件都收到 `file_ok` |
| R→S | `pause` / `resume` | | 接收端暂停 / 继续（发送端本地暂停不发消息） |
| 双向 | `cancel` | `reason` | 取消；接收端删除 `.ctpart` |
| 双向 | `error` | `code`, `msg` | 致命错误，会话终止 |

### manifest

```json
{
  "roots": [{"name": "dir", "dir": true}, {"name": "a.txt", "dir": false}],
  "dirs":  ["dir", "dir/sub", "dir/sub/empty"],
  "files": [{"path": "dir/sub/x.bin", "size": 123}, {"path": "a.txt", "size": 5}],
  "total_bytes": 128
}
```

- `path` / `dirs` 为 `/` 分隔的相对路径，首段必须是某个 root 的 `name`。
- 接收端按 `core/src/transfer/path_sanitize.h` 的规则拒绝：绝对路径、`\`、驱动器 / UNC 前缀、`.` / `..`、空段、控制字符、`: * ? " < > |`、段尾空格或点、Windows 保留设备名（含带扩展名）、非法 UTF-8、段 > 255 字节、总长 > 4096 字节。
- 文件数 ≤ 65535（16 位索引），单文件 ≤ 1100 × 2³² 字节。
- 每个 root 落到保存目录下时若重名，加 ` (1)`、` (2)` 后缀（文件后缀放在扩展名前）；重命名结果随续传记录持久化，续传不会再复制一份。

## 数据块（`data` 流）

```
magic 0x4342 "CB" (2) | ver 1 (1) | flags (1) | file_index (2) | block_index (4) | len (2) | payload[len]
```

- `len` ≤ 1100；除文件最后一块外均为 1100。块 `i` 对应文件偏移 `i × 1100`。
- `flags` bit0 = 该文件最后一块（仅提示）。
- 报文总长 ≤ 1112，低于 MiniRTC 非可靠单包上限 1150。

## SACK（`sack` 流）

```
magic 0x4353 "CS" (2) | ver 1 (1) | flags (1) | file_index (2) | run_count (2)
ack_base (4) | frontier (4) | received_count (4) | recv_rate_bps (4) | loss_permille (2) | reserved (2)
runs[run_count]: start (4) | length (4)
```

- `ack_base`：小于它的块全部已收；`frontier`：接收端见过的最高块 + 1；`received_count`：已收到的不同块数。
- `runs`：`[ack_base, frontier)` 之间缺失的块游程，升序，最多 140 条（报文 ≤ 1148 字节）；frontier 之后的尾巴不列出，发送端在 Sweep 完成后自行视为空洞。
- `flags` bit0 = 该文件位图已满。位图填满后接收端每 200 ms 重发一次 complete SACK，最多 5 次，直到 `file_ok` 经 ctrl 送达。
- 接收端每 60 ms 为有变化的文件发一份 SACK；`loss_permille` 为最近 500 ms 窗口内"按块号推算应到但未到"的比例。

## 发送端算法

1. **Sweep**：按 manifest 顺序，每文件顺序读（256 块一次 read）、算 SHA-256、跳过 `accept` 声称已有的块，其余按令牌桶速率发出。每 64 块穿插一次 Repair。
2. Sweep 完成即发 `file_done`，文件进入 in-flight（最多 8 个），继续下一文件。
3. **Repair**：对每个 in-flight 文件，把最新 SACK 的空洞加上 frontier 之后的尾巴逐块重发；同一块距上次发送不足 `max(120 ms, 1.5 × RTT + 60 ms)` 不重发（Sweep 阶段按 256 块一桶记时间，Repair 阶段逐块记）。
4. 收到 `file_ok` 的文件离开 in-flight；全部文件 `file_ok` 后发 `transfer_done`。
5. 速率：`target = clamp(min(AIMD, BWE × 1.1), 300 kbit/s, 1 Gbit/s)`，AIMD 由 SACK 的 `loss_permille` 驱动（> 100‰ ×0.7，> 30‰ ×0.9，否则每 200 ms + 2 Mbit/s）；MiniRTC 回压（`MiniRtcSend` 返回 1）优先。
6. 传输层连续 20 s 不可用（返回 -1）则失败。

## 接收端算法

1. `offer` 到达：校验 manifest，选定根目录名，创建目录树，为每个非空文件打开 `<final>.ctpart` 并预扩展到目标大小；空文件直接标记完成。
2. 块经写线程合并连续块后 `pwrite`，位图置位；同一块重复到达计入 `duplicates`。
3. 位图填满且已有 `file_done` 的哈希 → 校验 `.ctpart` 的 SHA-256 → 一致则改名为最终文件并发 `file_ok`；不一致则清位图、发 `file_bad`、等待重发。
4. 每 2 s 把各文件的已收游程交给 core 持久化到 `transfers.json`。
5. 全部文件校验通过 → 完成并清除续传记录。

## 续传

- 信令层：接收端进程重启后先用 `resume_token` claim，服务端把同一 session 重新配对（`once` 码失效后仍可）；token 被拒绝（分享已过期 / session 已被占）则回退用取件码。
- 传输层：新会话重新走 `offer` / `accept`；接收端只有在 manifest 签名（文件列表 SHA-256）与记录一致时才把已收游程放进 `accept`，否则从头开始。

## core 事件（`CtSetEventCallback`）

每个事件是一个 JSON 对象，含 `type` 与 `ts`（毫秒）：

| type | 字段 |
| --- | --- |
| `signal_state` | `state`（connecting / connected / failed / closed / reconnecting / tls_error）, `peer_id` |
| `share_state` | `id`, `share_id`, `state`（creating / ready / claimed / transferring / completed / closed / failed）, `mode`, `code`, `link`, `scheme_link`, `expires_at`, `files`, `bytes`, `receivers`, `completed`, `error` |
| `receive_state` | `transfer_id`, `code`, `state`（claiming / connecting / waiting_offer / transferring / completed / failed / cancelled / interrupted）, `save_dir`, `session_id`, `resumable`, `error_code`, `error_message`, `meta` |
| `transfer_state` / `transfer_progress` | `transfer_id`, `session_id`, `role`, `state`, `error_code`, `error_message`, `path`（p2p / turn / relay）, `bytes_total`, `bytes_done`, `files_total`, `files_done`, `rate_bps`, `loss_permille`, `current_file`, `eta_sec` |
| `config` | `config` |
| `error` | `code`, `message` |

`transfer_progress` 节流到 10 Hz。
