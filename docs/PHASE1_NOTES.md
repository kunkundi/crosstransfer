# 阶段 1 实施记录（2026-09-21）

## 交付

| 项 | 状态 |
| --- | --- |
| 根 `xmake.lua`：`minirtc` + `crosstransfer_core`（static）+ `ct_cli` + `core_tests`（doctest）+ 可选 `crosstransfer_native`（shared） | 完成；`crosstransfer_native` 仅写了配方，未构建验证 |
| `core/` 纯逻辑：取件码与链接编解码、路径清洗、块 / SACK / ctrl 编解码、位图、SHA-256（OpenSSL EVP）、定位读写、清单构建与校验 | 完成，单测覆盖往返 / 畸形输入 / 边界 |
| `core/` 运行时：`EventLoop`（单线程 + 定时器）、`Peer`（MiniRTC 封装 + 回调门控 + 后台销毁）、`SessionLink`（ctrl 队列 + 数据分发）、`Storage`（config.json / transfers.json） | 完成 |
| `core/` 传输引擎：`SenderTransfer`（Sweep / Repair，BWE 限速 + 丢包 AIMD 兜底）、`ReceiverTransfer`（写线程 + pwrite + SACK 定时 + SHA-256 校验 + 位图持久化） | 完成，内存管道 e2e 单测覆盖 0 丢包 / 5% 丢包 / 续传 / 校验失败重发 |
| `TransferSession` 状态机（offer / accept / file_done / file_ok / file_bad / pause / resume / cancel / transfer_done / error）与 `Core`（Share / Receive 管理、续传记录、事件 JSON） | 完成 |
| C API `core/include/crosstransfer/ct_api.h`（`CtCreate` … `CtVersion`） | 完成 |
| `ct_cli share / receive / resume / list` | 完成 |
| 单元测试 | 27 个用例、299 个断言全绿（含 ASan/UBSan 跑纯逻辑部分） |

## 端到端实测（本机回环，本地 `ctserver`）

| 场景 | 脚本 | 结果 |
| --- | --- | --- |
| 混合文件树（0 字节、< 1 块、= 1 块、多块、子目录、空目录、非 ASCII 名） | `tools/run_cli_e2e.sh p2p` | 通过，重复 15 次无失败 |
| 强制 TURN | `run_cli_e2e.sh turn --turn force` | 通过 |
| 强制 WSS 中继 | `run_cli_e2e.sh relay --relay force` | 通过，重复 5 次 |
| 5% 丢包 | `MINIRTC_TEST_DROP_PERCENT=5 run_cli_e2e.sh loss5 --turn off` | 通过，重复 5 次 |
| 1 GiB 随机文件 | `CT_E2E_BIG_MB=1024 run_cli_e2e.sh big1g` | 156 s，峰值 RSS 35 MB，内存平稳 |
| kill -9 接收端后凭 `resume_token` 续传 | `tools/run_cli_resume.sh 200 3` | 通过（第二次从位图位置继续，不产生第二份文件） |
| `open` 模式两接收端并发 + 同目录重名 | `tools/run_cli_open.sh` | 通过，得到 `dir` 与 `dir (1)` |
| 错误码 / 畸形码 | 手工 | `code_not_found` 正确上报；畸形输入 `CtReceiveStart` 返回 `CT_ERR_INVALID_ARG` |

## 与规划的偏差 / 决定

- **函数命名全部大驼峰**（用户要求）：C API 为 `CtCreate` / `CtShareCreate` …；MiniRTC C API 同步改为 `MiniRtcCreate` / `MiniRtcSend` …。
- **块头 12 字节，净荷 1100**：`magic(2) ver(1) flags(1) file(2) block(4) len(2)`；SACK 头 28 字节，除规划的 ack_base / 空洞游程 / 接收速率 / 丢包外增加 `frontier`（接收端见过的最高块 + 1），发送端据此只重发 frontier 以内的空洞，frontier 以外的尾巴由发送端自行推断，避免 SACK 报文装不下大空洞。
- **manifest 不带 SHA-256**：发送端在 Sweep 读文件时顺便算哈希，随 `file_done` 发送，省去分享前的整树预哈希（大目录秒开）。接收端位图填满且收到 `file_done` 后校验并改名。
- **校验失败自愈**：接收端 SHA-256 不符时清空该文件位图并发 `file_bad`，发送端清掉 `accept` 中声称已有的块，由 Repair 重发整个文件；不整个会话失败。
- **ctrl 分帧**：KCP 单条消息受 128 分片限制，ctrl JSON 按 16 KiB 分块，首字节 0x01 表示末块；大清单可达 16 MiB。
- **多文件流水**：最多 8 个已扫完的文件同时等待 `file_ok`，Sweep 不因单个小文件的 SACK 往返而停顿。
- **速率控制**：目标速率 = min(AIMD, BWE × 1.1)，AIMD 由接收端上报的丢包千分比驱动（> 10% 乘 0.7，> 3% 乘 0.9，否则每 200 ms 加 2 Mbit/s），下限 300 kbit/s；MiniRTC 回压（返回 1）始终优先。
- **续传记录**：`transfers.json` 保存 `resume_token`、清单签名（文件列表的 SHA-256）、根目录最终名（含去重后缀）与每文件已收游程；`offer` 到达后签名一致才应用，保证不会把不同分享的块写进同一个 `.ctpart`。
- **会话收尾**：传输完成后会话保留 1.5 s 让 `file_ok` / `transfer_done` 经 KCP 送达，再 `leave`；`CtDestroy` 同样先排空 ctrl 队列。
- **Share 与 session 关联**：`share_claimed` 的 `detail` 带 session id，core 据此把 sender 侧 session 归到正确的 share（`open` 模式多接收端需要）。
- MiniRTC 小修：`session_start.resumed` 是布尔，原先按整数读取导致日志恒为 `no`。

## 已知问题 / 后续

- **回环环境偶发 offer 未送达**（约 1/30）：双方 DTLS 完成、路径显示为 sender P2P / receiver TURN 的混合对（阶段 0 记录的回环特性），发送端的 KCP ctrl 未到达接收端，20 s 后以 `session_end` 结束。加了 ctrl 收发 debug 日志后 25 次未复现，待真实网络下观察；若复现，优先怀疑 libjuice 在回环下对非选中候选对来源报文的处理。
- **回环吞吐约 55 Mbit/s**，`sys` 时间占大头（每 1100 字节一次 sendto + SRTP）；后续可考虑更大的读块合并、减少 pacer 队列锁竞争。真实网络下瓶颈会是链路而非 CPU，暂不优化。
- `ReceiverTransfer` 队列上限 64 MiB，磁盘写不过来时丢块交给 SACK 修复；慢盘场景未实测。
- `crosstransfer_native` 共享库（`-force_load` / `--whole-archive`）在阶段 2 接 Flutter 时再验证；Windows / iOS 的 `core/` 编译同样待阶段 2 / 3。
- `MINIRTC_TEST_*` 测试钩子仍未加编译开关（阶段 0 遗留）。
