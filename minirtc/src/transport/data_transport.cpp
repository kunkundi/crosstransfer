/*
 * Copyright (c) 2025-2026 by DI JUNKUN, All Rights Reserved.
 */

#include "data_transport.h"

#include <algorithm>
#include <cstring>
#include <sstream>

#include "common.h"
#include "log.h"
#include "rtc_base/network/sent_packet.h"
#include "rtcp_common_header.h"
#include "rtp_feedback.h"
#include "rtp_packet_received.h"

namespace minirtc {

namespace {

constexpr int kKcpMtu = static_cast<int>(DataTransport::kMaxDatagramPayload);
constexpr size_t kRtcpBufferSize = 1200;
constexpr int64_t kMaxPacerQueueMs = 400;
constexpr int64_t kProcessIntervalTicks = 2;  // 2 × 10 ms

uint32_t Fnv1a(const std::string& s) {
  uint32_t h = 2166136261u;
  for (unsigned char c : s) {
    h ^= c;
    h *= 16777619u;
  }
  return h == 0 ? 1 : h;
}

bool LooksLikeRtcp(const uint8_t* data, size_t size) {
  if (size < 8) return false;
  if (((data[0] >> 6) & 0x03) != 2) return false;
  const uint8_t pt = data[1];
  return pt >= 192 && pt <= 223;
}

bool LooksLikeRtp(const uint8_t* data, size_t size) {
  if (size < kFixedHeaderSize) return false;
  if (((data[0] >> 6) & 0x03) != 2) return false;
  const uint8_t pt = data[1] & 0x7F;
  return pt == rtp::PAYLOAD_TYPE::DATA || pt == rtp::PAYLOAD_TYPE::KCP;
}

}  // namespace

DataTransport::DataTransport(std::shared_ptr<SystemClock> clock,
                             const std::vector<DataStreamConfig>& streams,
                             bool enable_srtp, DataFunc on_data)
    : clock_(clock),
      webrtc_clock_(webrtc::Clock::GetWebrtcClockShared(clock)),
      enable_srtp_(enable_srtp),
      on_data_(std::move(on_data)),
      rtcp_ssrc_(GenerateUniqueSsrc()) {
  for (const auto& cfg : streams) {
    auto s = std::make_unique<Stream>();
    s->owner = this;
    s->config = cfg;
    s->local_ssrc = GenerateUniqueSsrc();
    s->conv = Fnv1a(cfg.name);
    s->packetizer = RtpPacketizer::Create(
        cfg.reliable ? rtp::PAYLOAD_TYPE::KCP : rtp::PAYLOAD_TYPE::DATA,
        s->local_ssrc);
    if (!cfg.reliable && padding_stream_.empty()) padding_stream_ = cfg.name;
    by_local_ssrc_[s->local_ssrc] = s.get();
    streams_[cfg.name] = std::move(s);
  }
  SetPeriod(std::chrono::milliseconds(10));
  SetThreadName("DataTransport");
}

DataTransport::~DataTransport() { Destroy(); }

void DataTransport::Init() {
  if (running_.exchange(true)) return;
  if (enable_srtp_) SrtpEngine::GlobalInit();

  task_queue_cc_ = std::make_shared<TaskQueue>("cc");
  task_queue_pacer_ = std::make_shared<TaskQueue>("pacer");
  controller_ = std::make_unique<CongestionControl>();
  const int relay = relay_path_.load();
  if (relay >= 0) {
    controller_->SetRelayPath(
        relay == 1, webrtc::Timestamp::Millis(webrtc_clock_->TimeInMilliseconds()));
  }
  controller_->SetRepeatedInitialProbing(!padding_stream_.empty());

  // bounded queue: never drain faster than the estimate; Send() reports
  // backpressure once the expected queue time exceeds kMaxPacerQueueMs.
  pacer_ = std::make_shared<PacedSender>(webrtc_clock_, task_queue_pacer_, true);
  pacer_->SetPacingRates(webrtc::DataRate::BitsPerSec(2'000'000),
                         webrtc::DataRate::Zero());
  pacer_->SetSendBurstInterval(webrtc::TimeDelta::Millis(20));
  pacer_->SetQueueTimeLimit(webrtc::TimeDelta::Millis(kMaxPacerQueueMs));
  pacer_->SetAllowProbeWithoutMediaPacket(!padding_stream_.empty());
  pacer_->SetIncludeOverhead();
  pacer_->SetTransportOverhead(webrtc::DataSize::Bytes(28));  // IPv4+UDP

  std::weak_ptr<DataTransport> weak = weak_from_this();
  pacer_->SetOnSentPacketFunc(
      [weak](std::unique_ptr<webrtc::RtpPacketToSend> packet,
             const webrtc::PacedPacketInfo& info) {
        if (auto self = weak.lock()) self->OnPacedPacket(std::move(packet), info);
      });
  pacer_->SetGeneratePaddingFunc(
      [weak](uint32_t bytes, int64_t now_us)
          -> std::vector<std::unique_ptr<RtpPacket>> {
        if (auto self = weak.lock()) return self->GeneratePadding(bytes, now_us);
        return {};
      });

  feedback_gen_ = std::make_unique<webrtc::CongestionControlFeedbackGenerator>(
      webrtc_clock_,
      [weak](std::vector<std::unique_ptr<RtcpPacket>> packets) {
        if (auto self = weak.lock()) self->SendRtcp(std::move(packets));
      });

  last_stats_ms_ = clock_->CurrentTimeMs();
  Start();
}

void DataTransport::Destroy() {
  if (!running_.exchange(false)) return;
  Stop();
  if (pacer_) pacer_->Shutdown();
  if (task_queue_pacer_) task_queue_pacer_->Stop();
  if (task_queue_cc_) task_queue_cc_->Stop();
  std::unique_lock lock(streams_mutex_);
  for (auto& [_, s] : streams_) {
    std::lock_guard<std::mutex> kl(s->kcp_mutex);
    if (s->kcp) {
      ikcp_release(s->kcp);
      s->kcp = nullptr;
    }
  }
}

void DataTransport::SetSendFunc(SendFunc f) {
  std::lock_guard<std::mutex> lock(send_mutex_);
  send_ = std::move(f);
}

int DataTransport::SendDatagram(const uint8_t* data, size_t size) {
  std::lock_guard<std::mutex> lock(send_mutex_);
  if (!send_) return -1;
  return send_(data, size);
}

uint32_t DataTransport::NowMs() const {
  return static_cast<uint32_t>(clock_->CurrentTimeMs());
}

// ---- SDP ------------------------------------------------------------------

std::string DataTransport::LocalStreamSdpLines() const {
  std::shared_lock lock(streams_mutex_);
  std::ostringstream os;
  for (const auto& [name, s] : streams_) {
    os << "a=x-data-stream:" << name << " " << s->local_ssrc << " "
       << (s->config.reliable ? 1 : 0) << "\r\n";
  }
  return os.str();
}

bool DataTransport::ParseRemoteStreams(const std::string& sdp) {
  std::unique_lock lock(streams_mutex_);
  by_remote_ssrc_.clear();
  std::istringstream lines(sdp);
  std::string line;
  size_t matched = 0;
  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.rfind("a=x-data-stream:", 0) != 0) continue;
    std::istringstream fields(line.substr(16));
    std::string name;
    uint32_t ssrc = 0;
    int reliable = 0;
    if (!(fields >> name >> ssrc >> reliable) || ssrc == 0) {
      LOG_WARN("Malformed x-data-stream line [{}]", line);
      return false;
    }
    auto it = streams_.find(name);
    if (it == streams_.end()) {
      LOG_WARN("Remote advertises unknown stream [{}]", name);
      continue;
    }
    if ((reliable != 0) != it->second->config.reliable) {
      LOG_ERROR("Stream [{}] reliability mismatch", name);
      return false;
    }
    it->second->remote_ssrc = ssrc;
    by_remote_ssrc_[ssrc] = it->second.get();
    ++matched;
  }
  if (matched != streams_.size()) {
    LOG_ERROR("Remote is missing {} data stream(s)", streams_.size() - matched);
    return false;
  }
  return true;
}

// ---- SRTP -----------------------------------------------------------------

bool DataTransport::SetSrtpKeys(const std::vector<uint8_t>& local_key,
                                const std::vector<uint8_t>& local_salt,
                                const std::vector<uint8_t>& remote_key,
                                const std::vector<uint8_t>& remote_salt) {
  if (local_key.size() != 16 || local_salt.size() != 12 ||
      remote_key.size() != 16 || remote_salt.size() != 12) {
    return false;
  }
  SrtpEngine::Params out{};
  std::memcpy(out.key, local_key.data(), 16);
  std::memcpy(out.salt, local_salt.data(), 12);
  out.sender_any_outbound = true;
  SrtpEngine::Params in{};
  std::memcpy(in.key, remote_key.data(), 16);
  std::memcpy(in.salt, remote_salt.data(), 12);
  in.receiver_any_inbound = true;
  auto o = SrtpEngine::CreateSenderPtr(out);
  auto i = SrtpEngine::CreateReceiverPtr(in);
  if (!o->valid() || !i->valid()) return false;
  {
    std::lock_guard<std::mutex> lock(send_mutex_);
    srtp_out_ = std::move(o);
  }
  {
    std::lock_guard<std::mutex> lock(srtp_in_mutex_);
    srtp_in_ = std::move(i);
  }
  srtp_ready_ = true;
  LOG_INFO("SRTP sessions installed");
  return true;
}

// ---- readiness --------------------------------------------------------------

void DataTransport::SetTransportReady(bool ready) {
  const bool was = transport_ready_.exchange(ready);
  if (!running_.load()) return;
  if (pacer_ && task_queue_pacer_) {
    auto pacer = pacer_;
    task_queue_pacer_->PostTask([pacer, ready, was]() {
      pacer->SetTransportReady(ready);
      if (ready && !was) pacer->EnsureStarted();
    });
  }
  if (controller_ && task_queue_cc_ && ready != was) {
    task_queue_cc_->PostTask([this, ready]() {
      if (!controller_) return;
      webrtc::NetworkAvailability msg;
      msg.at_time = webrtc::Timestamp::Millis(webrtc_clock_->TimeInMilliseconds());
      msg.network_available = ready;
      PostUpdates(controller_->OnNetworkAvailability(msg));
    });
  }
}

void DataTransport::SetRelayPath(bool relay) {
  relay_path_.store(relay ? 1 : 0);
  if (!running_.load() || !task_queue_cc_) return;
  task_queue_cc_->PostTask([this, relay]() {
    if (!controller_) return;
    PostUpdates(controller_->SetRelayPath(
        relay, webrtc::Timestamp::Millis(webrtc_clock_->TimeInMilliseconds())));
  });
}

// ---- send path --------------------------------------------------------------

int DataTransport::Send(const std::string& stream, const uint8_t* data,
                        size_t size) {
  if (!running_.load() || !data || size == 0) return -1;
  if (!transport_ready_.load()) return -1;
  std::shared_lock lock(streams_mutex_);
  auto it = streams_.find(stream);
  if (it == streams_.end()) {
    LOG_ERROR("Unknown data stream [{}]", stream);
    return -1;
  }
  Stream& s = *it->second;
  if (s.config.reliable) {
    InitKcp(s);
    std::lock_guard<std::mutex> kl(s.kcp_mutex);
    if (!s.kcp) return -1;
    if (ikcp_waitsnd(s.kcp) >= s.kcp->snd_wnd * 2) return 1;
    if (ikcp_send(s.kcp, reinterpret_cast<const char*>(data),
                  static_cast<int>(size)) < 0) {
      return -1;
    }
    ikcp_flush(s.kcp);
    return 0;
  }
  if (size > kMaxDatagramPayload) return -1;
  if (pacer_->ExpectedQueueTime() > webrtc::TimeDelta::Millis(kMaxPacerQueueMs)) {
    return 1;
  }
  EnqueueRtp(s, data, size);
  return 0;
}

void DataTransport::EnqueueRtp(Stream& s, const uint8_t* payload, size_t size) {
  auto packets = s.packetizer->Build(const_cast<uint8_t*>(payload),
                                     static_cast<uint32_t>(size), NowMs(), true);
  if (packets.empty()) return;
  pacer_->EnqueueRtpPackets(packets, clock_->CurrentTimeUs(), s.config.name);
}

void DataTransport::InitKcp(Stream& s) {
  std::lock_guard<std::mutex> kl(s.kcp_mutex);
  if (s.kcp) return;
  s.kcp = ikcp_create(s.conv, &s);
  if (!s.kcp) return;
  ikcp_nodelay(s.kcp, 1, 10, 2, 1);
  ikcp_wndsize(s.kcp, s.config.kcp_window, s.config.kcp_window);
  ikcp_setmtu(s.kcp, kKcpMtu);
  s.kcp->rx_minrto = 10;
  s.kcp->output = &DataTransport::KcpOutput;
  s.kcp->user = &s;
}

int DataTransport::KcpOutput(const char* buf, int len, ikcpcb*, void* user) {
  auto* s = static_cast<Stream*>(user);
  if (!s || !s->owner || !buf || len <= 0) return 0;
  s->owner->EnqueueRtp(*s, reinterpret_cast<const uint8_t*>(buf),
                       static_cast<size_t>(len));
  return len;
}

void DataTransport::DrainKcp(Stream& s) {
  std::vector<std::vector<uint8_t>> messages;
  {
    std::lock_guard<std::mutex> kl(s.kcp_mutex);
    if (!s.kcp) return;
    for (;;) {
      const int n = ikcp_peeksize(s.kcp);
      if (n <= 0) break;
      std::vector<uint8_t> buf(static_cast<size_t>(n));
      const int r = ikcp_recv(s.kcp, reinterpret_cast<char*>(buf.data()), n);
      if (r <= 0) break;
      buf.resize(static_cast<size_t>(r));
      messages.push_back(std::move(buf));
    }
  }
  for (auto& m : messages) {
    if (on_data_) on_data_(m.data(), m.size(), s.config.name);
  }
}

std::vector<std::unique_ptr<RtpPacket>> DataTransport::GeneratePadding(
    uint32_t bytes, int64_t /*now_us*/) {
  std::vector<std::unique_ptr<RtpPacket>> out;
  std::shared_lock lock(streams_mutex_);
  auto it = streams_.find(padding_stream_);
  if (it == streams_.end()) return out;
  const Stream& s = *it->second;
  uint32_t remaining = bytes;
  while (remaining > 0 && out.size() < 16) {
    const uint32_t pad = std::min<uint32_t>(remaining, 255);
    std::vector<uint8_t> frame(kFixedHeaderSize + pad, 0);
    frame[0] = (2 << 6) | (1 << 5);  // V=2, P=1
    frame[1] = static_cast<uint8_t>(rtp::PAYLOAD_TYPE::DATA);
    const uint32_t ts = NowMs();
    frame[4] = ts >> 24; frame[5] = ts >> 16; frame[6] = ts >> 8; frame[7] = ts;
    frame[8] = s.local_ssrc >> 24; frame[9] = s.local_ssrc >> 16;
    frame[10] = s.local_ssrc >> 8; frame[11] = s.local_ssrc;
    frame.back() = static_cast<uint8_t>(pad);
    auto p = std::make_unique<webrtc::RtpPacketToSend>();
    if (p->Build(frame.data(), static_cast<uint32_t>(frame.size()))) {
      p->set_stream_name(s.config.name);
      out.push_back(std::move(p));
    }
    remaining -= pad;
  }
  return out;
}

DataTransport::FeedbackRegistration DataTransport::RegisterForFeedback(
    const webrtc::RtpPacketToSend& p, const webrtc::PacedPacketInfo& info,
    size_t send_size) {
  FeedbackRegistration reg;
  reg.send_time_ms = clock_->CurrentTimeMs();
  reg.send_size = send_size;
  const auto seq = p.transport_sequence_number();
  reg.tracked = seq.has_value();
  if (!reg.tracked) return reg;
  rtc::SentPacket sent;
  sent.packet_id = static_cast<int>(*seq);
  sent.send_time_ms = reg.send_time_ms;
  sent.info.included_in_feedback = true;
  sent.info.included_in_allocation = true;
  sent.info.packet_size_bytes = send_size;
  sent.info.packet_type = rtc::PacketType::kData;
  std::lock_guard<std::mutex> lock(feedback_mutex_);
  feedback_adapter_.AddPacket(p, info, send_size - p.size(),
                              webrtc::Timestamp::Millis(reg.send_time_ms));
  feedback_adapter_.ProcessSentPacket(sent);
  return reg;
}

void DataTransport::RollbackFeedback(const webrtc::RtpPacketToSend& p,
                                     const FeedbackRegistration& reg) {
  if (!reg.tracked) return;
  std::lock_guard<std::mutex> lock(feedback_mutex_);
  feedback_adapter_.RemovePacket(p);
}

void DataTransport::OnSentPacket(const webrtc::RtpPacketToSend&,
                                 const FeedbackRegistration& reg) {
  sent_packets_.fetch_add(1);
  sent_bytes_.fetch_add(reg.send_size);
  if (!task_queue_cc_) return;
  const size_t size = reg.send_size;
  const auto at = webrtc::Timestamp::Millis(reg.send_time_ms);
  task_queue_cc_->PostTask([this, size, at]() {
    if (controller_) controller_->OnSentPacket(size, at);
  });
}

void DataTransport::OnPacedPacket(std::unique_ptr<webrtc::RtpPacketToSend> packet,
                                  const webrtc::PacedPacketInfo& info) {
  if (!packet || !running_.load()) return;
  const uint8_t* buf = packet->Buffer().data();
  size_t size = packet->Size();
  if (enable_srtp_) {
    std::shared_ptr<SrtpEngine::SrtpSession> srtp;
    {
      std::lock_guard<std::mutex> lock(send_mutex_);
      srtp = srtp_out_;
    }
    if (!srtp || !srtp->valid()) return;  // not yet keyed: drop
    if (protect_scratch_.size() < size + 64) protect_scratch_.resize(size + 64);
    std::memcpy(protect_scratch_.data(), buf, size);
    int len = static_cast<int>(size);
    const int r = srtp->protectRtp(protect_scratch_.data(), &len);
    if (r < 0) {
      LOG_ERROR("SRTP protect failed: {}",
                SrtpEngine::ErrToStr(static_cast<srtp_err_status_t>(-r)));
      return;
    }
    buf = protect_scratch_.data();
    size = static_cast<size_t>(len);
  }
  const FeedbackRegistration reg = RegisterForFeedback(*packet, info, size);
  if (SendDatagram(buf, size) < 0) {
    RollbackFeedback(*packet, reg);
    return;
  }
  OnSentPacket(*packet, reg);
}

void DataTransport::PostUpdates(webrtc::NetworkControlUpdate update) {
  if (update.congestion_window) {
    congestion_window_ = *update.congestion_window;
    UpdateCongestedState();
  }
  if (update.pacer_config && pacer_ && task_queue_pacer_) {
    const auto rate = update.pacer_config->data_rate();
    const auto pad = update.pacer_config->pad_rate();
    pacing_bps_.store(rate.bps());
    auto pacer = pacer_;
    task_queue_pacer_->PostTask([pacer, rate, pad]() {
      pacer->SetPacingRates(rate, pad);
    });
  }
  if (!update.probe_cluster_configs.empty() && pacer_ && task_queue_pacer_) {
    auto pacer = pacer_;
    auto probes = std::move(update.probe_cluster_configs);
    task_queue_pacer_->PostTask([pacer, probes = std::move(probes)]() mutable {
      pacer->CreateProbeClusters(std::move(probes));
    });
  }
  if (update.target_rate) {
    target_bps_.store(update.target_rate->target_rate.bps());
    const auto& est = update.target_rate->network_estimate;
    if (est.round_trip_time.IsFinite()) {
      rtt_ms_.store(static_cast<int32_t>(est.round_trip_time.ms()));
    }
    loss_.store(est.loss_rate_ratio);
  }
}

void DataTransport::UpdateCongestedState() {
  if (!congestion_window_.IsFinite()) return;
  webrtc::DataSize outstanding;
  {
    std::lock_guard<std::mutex> lock(feedback_mutex_);
    outstanding = feedback_adapter_.GetOutstandingData();
  }
  const bool congested = outstanding >= congestion_window_;
  if (congested_.exchange(congested) != congested && pacer_) {
    auto pacer = pacer_;
    task_queue_pacer_->PostTask([pacer, congested]() {
      pacer->SetCongested(congested);
    });
  }
}

// ---- receive path -----------------------------------------------------------

void DataTransport::OnDatagram(const uint8_t* data, size_t size) {
  if (!running_.load() || !data) return;
  if (LooksLikeRtcp(data, size)) {
    HandleRtcp(data, size);
  } else if (LooksLikeRtp(data, size)) {
    HandleRtp(data, size);
  }
}

void DataTransport::HandleRtcp(const uint8_t* data, size_t size) {
  std::vector<uint8_t> buf(data, data + size);
  int len = static_cast<int>(size);
  if (enable_srtp_) {
    std::shared_ptr<SrtpEngine::SrtpSession> srtp;
    {
      std::lock_guard<std::mutex> lock(srtp_in_mutex_);
      srtp = srtp_in_;
    }
    if (!srtp) return;
    if (srtp->unprotectRtcp(buf.data(), &len) < 0) {
      LOG_WARN("SRTCP unprotect failed");
      return;
    }
  }
  const uint8_t* next = buf.data();
  size_t remaining = static_cast<size_t>(len);
  while (remaining > 0) {
    RtcpCommonHeader header;
    if (!header.Parse(next, remaining)) return;
    const size_t block = header.packet_size();
    if (block == 0 || block > remaining) return;
    if (header.type() == RtpFeedback::kPacketType &&
        header.fmt() ==
            webrtc::rtcp::CongestionControlFeedback::kFeedbackMessageType) {
      webrtc::rtcp::CongestionControlFeedback feedback;
      if (feedback.Parse(header) && !feedback.packets().empty()) {
        std::optional<webrtc::TransportPacketsFeedback> msg;
        {
          std::lock_guard<std::mutex> lock(feedback_mutex_);
          msg = feedback_adapter_.ProcessCongestionControlFeedback(
              feedback, webrtc::Timestamp::Micros(clock_->CurrentTimeUs()));
        }
        if (msg && task_queue_cc_) {
          task_queue_cc_->PostTask([this, msg]() {
            if (controller_) PostUpdates(controller_->OnTransportPacketsFeedback(*msg));
          });
          UpdateCongestedState();
        }
      }
    }
    next = header.NextPacket();
    remaining -= block;
  }
}

void DataTransport::HandleRtp(const uint8_t* data, size_t size) {
  std::vector<uint8_t> buf(data, data + size);
  int len = static_cast<int>(size);
  if (enable_srtp_) {
    std::shared_ptr<SrtpEngine::SrtpSession> srtp;
    {
      std::lock_guard<std::mutex> lock(srtp_in_mutex_);
      srtp = srtp_in_;
    }
    if (!srtp) return;
    const int r = srtp->unprotectRtp(buf.data(), &len);
    if (r < 0) {
      LOG_WARN("SRTP unprotect failed: {}",
               SrtpEngine::ErrToStr(static_cast<srtp_err_status_t>(-r)));
      return;
    }
  }
  webrtc::RtpPacketReceived packet;
  if (!packet.Build(buf.data(), static_cast<uint32_t>(len))) return;
  packet.set_arrival_time(webrtc_clock_->CurrentTime());
  recv_packets_.fetch_add(1);
  recv_bytes_.fetch_add(size);

  Stream* stream = nullptr;
  {
    std::shared_lock lock(streams_mutex_);
    auto it = by_remote_ssrc_.find(packet.Ssrc());
    if (it != by_remote_ssrc_.end()) stream = it->second;
  }
  if (!stream) return;

  {
    std::lock_guard<std::mutex> lock(feedback_gen_mutex_);
    if (feedback_gen_) feedback_gen_->OnReceivedPacket(packet);
  }
  if (packet.PayloadSize() == 0) return;  // padding / probe

  if (stream->config.reliable) {
    InitKcp(*stream);
    {
      std::lock_guard<std::mutex> kl(stream->kcp_mutex);
      if (!stream->kcp) return;
      if (ikcp_input(stream->kcp,
                     reinterpret_cast<const char*>(packet.Payload()),
                     static_cast<long>(packet.PayloadSize())) < 0) {
        return;
      }
      ikcp_update(stream->kcp, NowMs());
    }
    DrainKcp(*stream);
  } else if (on_data_) {
    on_data_(packet.Payload(), packet.PayloadSize(), stream->config.name);
  }
}

void DataTransport::SendRtcp(std::vector<std::unique_ptr<RtcpPacket>> packets) {
  uint8_t buffer[kRtcpBufferSize + 64];
  size_t index = 0;
  auto flush = [&](const uint8_t* data, size_t size) {
    if (size == 0) return;
    std::vector<uint8_t> out(data, data + size);
    int len = static_cast<int>(size);
    if (enable_srtp_) {
      std::shared_ptr<SrtpEngine::SrtpSession> srtp;
      {
        std::lock_guard<std::mutex> lock(send_mutex_);
        srtp = srtp_out_;
      }
      if (!srtp) return;
      out.resize(size + 64);
      if (srtp->protectRtcp(out.data(), &len) < 0) return;
    }
    SendDatagram(out.data(), static_cast<size_t>(len));
  };
  for (auto& p : packets) {
    p->SetSenderSsrc(rtcp_ssrc_);
    p->Create(buffer, &index, kRtcpBufferSize,
              [&](const uint8_t* d, size_t s) { flush(d, s); });
  }
  flush(buffer, index);
}

// ---- periodic -----------------------------------------------------------------

bool DataTransport::Process() {
  if (!running_.load()) return false;
  const uint32_t now = NowMs();
  {
    std::shared_lock lock(streams_mutex_);
    for (auto& [_, s] : streams_) {
      bool drain = false;
      {
        std::lock_guard<std::mutex> kl(s->kcp_mutex);
        if (s->kcp) {
          ikcp_update(s->kcp, now);
          drain = ikcp_peeksize(s->kcp) > 0;
        }
      }
      if (drain) DrainKcp(*s);
    }
  }
  {
    std::lock_guard<std::mutex> lock(feedback_gen_mutex_);
    if (feedback_gen_) feedback_gen_->Process(webrtc_clock_->CurrentTime());
  }
  if (++tick_ % kProcessIntervalTicks == 0 && task_queue_cc_) {
    task_queue_cc_->PostTask([this]() {
      if (!controller_) return;
      webrtc::ProcessInterval msg;
      msg.at_time = webrtc::Timestamp::Millis(webrtc_clock_->TimeInMilliseconds());
      PostUpdates(controller_->OnProcessInterval(msg));
    });
  }
  return true;
}

MiniRtcLinkEstimate DataTransport::Estimate() const {
  MiniRtcLinkEstimate e{};
  e.bwe_bps = target_bps_.load();
  e.pacing_bps = pacing_bps_.load();
  e.rtt_ms = rtt_ms_.load();
  e.loss = loss_.load();
  e.srtp_active = srtp_ready_.load();
  const int relay = relay_path_.load();
  e.path = relay < 0 ? MINIRTC_PATH_UNKNOWN
                     : (relay == 1 ? MINIRTC_PATH_TURN : MINIRTC_PATH_P2P);
  return e;
}

MiniRtcNetStats DataTransport::TakeStats() {
  MiniRtcNetStats s{};
  const int64_t now = clock_->CurrentTimeMs();
  const int64_t dt = std::max<int64_t>(1, now - last_stats_ms_);
  const uint64_t sb = sent_bytes_.load(), rb = recv_bytes_.load();
  s.send_bitrate_bps = static_cast<uint32_t>((sb - last_sent_bytes_) * 8000 / dt);
  s.recv_bitrate_bps = static_cast<uint32_t>((rb - last_recv_bytes_) * 8000 / dt);
  last_sent_bytes_ = sb;
  last_recv_bytes_ = rb;
  last_stats_ms_ = now;
  s.sent_packets = sent_packets_.load();
  s.recv_packets = recv_packets_.load();
  s.sent_bytes = sb;
  s.recv_bytes = rb;
  s.link = Estimate();
  return s;
}

}  // namespace minirtc
