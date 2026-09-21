# 阶段 0 实施记录（2026-09-21）

## 交付

| 项 | 状态 |
| --- | --- |
| `server/`：信令、取件码、TURN 凭据、内嵌 TURN、WSS 中继、healthz/metrics、Dockerfile/compose | 完成，`go test -race` 全绿 |
| `minirtc/`：删媒体/浏览器/libnice/glib；`ice_agent` 改 libjuice + miniupnpc；重写 `pc/`、`DataTransport`（替代 `ice_transport_controller`）、SDP；新 C API | 完成 |
| 四平台编译 | macOS arm64、iOS arm64、Linux arm64（Ubuntu 24.04 Docker，`xmake f -p linux`）通过；Windows 未实测（本机无 MSVC/MinGW） |
| `data_echo` 经本地 server：P2P / 强制 TURN / WSS 中继 | 全部通过（含 DTLS-SRTP） |
| 数据路径：非可靠流接 pacer + BWE，暴露 `minirtc_get_link_estimate`；KCP 窗口可配 | 完成 |
| 限速 / 丢包实测 | 5% 丢包：可靠流完整、非可靠流丢约 5%；8 Mbit/s 限速：BWE 收敛到约 7 Mbit/s、稳态零丢包 |

## 与规划的偏差 / 决定

- **libjuice 1.7.2 未打补丁**（MPL 义务为零）。为保证角色分配稳定，应答方在应用远端 offer 之后才开始收集候选（controlled），offerer 是 DTLS client。
- 本地 SDP 只含 ICE 属性 + 指纹 + `a=x-data-stream` 行；所有候选（含 host）都经 trickle 发送，便于 `MINIRTC_TURN_FORCE` 过滤与 UPnP 追加候选。
- **强制 TURN** 通过只发/只收 relay 候选实现；libjuice 仍可能把对端的 relay 地址配成 prflx 直连，实际路径以 `selected pair` 日志为准（本机回环测试可见 P2P/TURN 混合，这是回环环境特性）。
- WSS 中继：`force_ws_relay` 跳过 ICE；ICE 失败或 `ice_timeout_ms` 超时自动切换；服务端发送队列满时**丢弃**中继帧而非断连；未知 session 的帧静默丢弃。
- 拥塞控制参数：pacing factor 2.5 → 1.15；有界 pacer 队列（不超速排空）；网络上限 20 → 200 Mbit/s；AIMD 起始 30 → 200 Mbit/s。KCP 段走"音频"优先级，块数据走普通优先级。
- `PeerConnection` 的会话状态变更全部串行到一个 worker 队列，libjuice / WebSocket / pacer 线程互不阻塞；libjuice 回调中只做数据路径。
- `aimd_rate_control.cc` 中外部贡献的一行 `beta_` 初始化已重写为头文件默认成员初始化。
- `server/go.mod` 固定 `go 1.25`，`golang.org/x/*` 固定到 1.25 兼容版本。

## 已知问题 / 后续

- Windows 编译与 `ws_client_tls.cpp` 的 Windows 分支需在 CI（阶段 5）验证；Linux 只验证了编译，`data_echo` 未在 Linux 上运行。
- 回环环境下 ICE 完成时间偶尔超过 4 s（libjuice STUN 重传节奏），已按 15 s 超时处理；真实网络下待实测成功率。
- 中继模式吞吐受 WebSocket 帧开销与服务端限速影响，未压测。
- `MINIRTC_TEST_DROP_PERCENT` / `MINIRTC_TEST_LINK_KBPS` 是测试钩子，发布构建前应加编译开关移除。
