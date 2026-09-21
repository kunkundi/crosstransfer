/*
 * Copyright (c) 2025-2026 by DI JUNKUN, All Rights Reserved.
 */

#ifndef MINIRTC_DATA_TRANSPORT_H_
#define MINIRTC_DATA_TRANSPORT_H_

#include <ikcp.h>

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>
#include <vector>

#include "api/clock/clock.h"
#include "api/transport/network_types.h"
#include "clock/system_clock.h"
#include "congestion_control.h"
#include "congestion_control_feedback.h"
#include "congestion_control_feedback_generator.h"
#include "minirtc.h"
#include "paced_sender.h"
#include "rtp_packetizer.h"
#include "srtp_engine.h"
#include "task_queue.h"
#include "thread_base.h"
#include "transport_feedback_adapter.h"

namespace minirtc {

struct DataStreamConfig {
  std::string name;
  bool reliable = false;
  int kcp_window = 1024;
};

// Data-only transport: named RTP data streams (reliable via KCP, unreliable
// raw) over one datagram path, with SRTP, pacing, send-side delay based BWE
// (RFC 8888 feedback) and receive-side feedback generation. Path agnostic:
// the owner supplies a send function and feeds incoming datagrams.
class DataTransport : public std::enable_shared_from_this<DataTransport>,
                      public ThreadBase {
 public:
  using SendFunc = std::function<int(const uint8_t*, size_t)>;
  using DataFunc =
      std::function<void(const uint8_t*, size_t, const std::string& stream)>;

  static constexpr size_t kMaxDatagramPayload = 1150;

  DataTransport(std::shared_ptr<SystemClock> clock,
                const std::vector<DataStreamConfig>& streams, bool enable_srtp,
                DataFunc on_data);
  ~DataTransport();

  // Must be called once before use (needs shared_from_this).
  void Init();
  void Destroy();

  void SetSendFunc(SendFunc f);

  // "a=x-data-stream:<name> ssrc:<n> reliable:<0|1>" lines for the local SDP.
  std::string LocalStreamSdpLines() const;
  // Parse the remote peer's x-data-stream lines; returns false if a stream
  // registered locally is missing remotely or reliability disagrees.
  bool ParseRemoteStreams(const std::string& sdp);

  // Install DTLS-derived SRTP keys (AES-128-GCM). Enables protection.
  bool SetSrtpKeys(const std::vector<uint8_t>& local_key,
                   const std::vector<uint8_t>& local_salt,
                   const std::vector<uint8_t>& remote_key,
                   const std::vector<uint8_t>& remote_salt);
  bool SrtpActive() const { return srtp_ready_.load(); }

  // Transport usable (ICE/relay path up and, if SRTP, keys installed).
  void SetTransportReady(bool ready);
  void SetRelayPath(bool relay);

  // Incoming RTP/RTCP datagram (already demuxed from DTLS by the owner).
  void OnDatagram(const uint8_t* data, size_t size);

  // 0 ok, 1 backpressure (retry later), -1 error.
  int Send(const std::string& stream, const uint8_t* data, size_t size);

  MiniRtcLinkEstimate Estimate() const;
  // Snapshot of counters; rates are over the interval since the last call.
  MiniRtcNetStats TakeStats();

 private:
  struct Stream {
    DataTransport* owner = nullptr;
    DataStreamConfig config;
    uint32_t local_ssrc = 0;
    uint32_t remote_ssrc = 0;
    uint32_t conv = 0;
    std::unique_ptr<RtpPacketizer> packetizer;
    ikcpcb* kcp = nullptr;
    std::mutex kcp_mutex;
    uint32_t last_kcp_update_ms = 0;
  };

  struct FeedbackRegistration {
    int64_t send_time_ms = 0;
    size_t send_size = 0;
    bool tracked = false;
  };

  bool Process() override;  // 10 ms tick: KCP update, feedback, CC interval

  void OnPacedPacket(std::unique_ptr<webrtc::RtpPacketToSend> packet,
                     const webrtc::PacedPacketInfo& info);
  std::vector<std::unique_ptr<RtpPacket>> GeneratePadding(uint32_t bytes,
                                                          int64_t now_us);
  FeedbackRegistration RegisterForFeedback(const webrtc::RtpPacketToSend& p,
                                           const webrtc::PacedPacketInfo& info,
                                           size_t send_size);
  void RollbackFeedback(const webrtc::RtpPacketToSend& p,
                        const FeedbackRegistration& reg);
  void OnSentPacket(const webrtc::RtpPacketToSend& p,
                    const FeedbackRegistration& reg);
  void PostUpdates(webrtc::NetworkControlUpdate update);
  void UpdateCongestedState();

  void HandleRtcp(const uint8_t* data, size_t size);
  void HandleRtp(const uint8_t* data, size_t size);
  void SendRtcp(std::vector<std::unique_ptr<RtcpPacket>> packets);
  int SendDatagram(const uint8_t* data, size_t size);

  void EnqueueRtp(Stream& s, const uint8_t* payload, size_t size);
  static int KcpOutput(const char* buf, int len, ikcpcb* kcp, void* user);
  void InitKcp(Stream& s);
  void DrainKcp(Stream& s);
  uint32_t NowMs() const;

  std::shared_ptr<SystemClock> clock_;
  std::shared_ptr<webrtc::Clock> webrtc_clock_;
  const bool enable_srtp_;
  DataFunc on_data_;
  SendFunc send_;
  std::mutex send_mutex_;

  std::map<std::string, std::unique_ptr<Stream>> streams_;
  std::map<uint32_t, Stream*> by_remote_ssrc_;
  std::map<uint32_t, Stream*> by_local_ssrc_;
  mutable std::shared_mutex streams_mutex_;
  std::string padding_stream_;

  // SRTP
  std::shared_ptr<SrtpEngine::SrtpSession> srtp_out_;
  std::shared_ptr<SrtpEngine::SrtpSession> srtp_in_;
  std::mutex srtp_in_mutex_;
  std::atomic<bool> srtp_ready_{false};

  // Send side congestion control
  std::shared_ptr<TaskQueue> task_queue_cc_;
  std::shared_ptr<TaskQueue> task_queue_pacer_;
  std::unique_ptr<CongestionControl> controller_;
  std::shared_ptr<PacedSender> pacer_;
  webrtc::TransportFeedbackAdapter feedback_adapter_;
  mutable std::mutex feedback_mutex_;
  webrtc::DataSize congestion_window_ = webrtc::DataSize::PlusInfinity();
  std::atomic<bool> congested_{false};
  std::vector<uint8_t> protect_scratch_;

  // Receive side feedback
  std::unique_ptr<webrtc::CongestionControlFeedbackGenerator> feedback_gen_;
  std::mutex feedback_gen_mutex_;

  std::atomic<bool> transport_ready_{false};
  std::atomic<bool> running_{false};
  std::atomic<int> relay_path_{-1};
  uint32_t rtcp_ssrc_ = 0;
  int tick_ = 0;

  // Estimates / stats
  std::atomic<int64_t> target_bps_{0};
  std::atomic<int64_t> pacing_bps_{0};
  std::atomic<int32_t> rtt_ms_{-1};
  std::atomic<float> loss_{0.0f};
  std::atomic<uint64_t> sent_packets_{0}, sent_bytes_{0};
  std::atomic<uint64_t> recv_packets_{0}, recv_bytes_{0};
  uint64_t last_sent_bytes_ = 0, last_recv_bytes_ = 0;
  int64_t last_stats_ms_ = 0;
};

}  // namespace minirtc

#endif
