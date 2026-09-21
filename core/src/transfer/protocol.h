/*
 * CrossTransfer core — wire protocol constants.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_PROTOCOL_H_
#define CT_TRANSFER_PROTOCOL_H_

#include <cstddef>
#include <cstdint>

namespace ct {

// Version of the ctrl / block / sack protocol spoken between two cores.
constexpr uint8_t kProtoVersion = 1;

// Named MiniRTC data streams (must match on both ends; see MiniRtcAddDataStream).
constexpr const char* kStreamCtrl = "ctrl";  // reliable (KCP)
constexpr const char* kStreamData = "data";  // unreliable, one block per datagram
constexpr const char* kStreamSack = "sack";  // unreliable, one SACK per datagram

// Largest payload MiniRtcSend accepts on an unreliable stream.
constexpr size_t kMaxDatagram = 1150;

// Data block: header + payload. Payload of every block except the last one of
// a file is exactly kBlockPayloadSize bytes.
constexpr uint16_t kBlockMagic = 0x4342;  // "CB"
constexpr size_t kBlockHeaderSize = 12;   // magic(2) ver(1) flags(1) file(2) block(4) len(2)
constexpr size_t kBlockPayloadSize = 1100;
constexpr uint8_t kBlockFlagLast = 0x01;  // last block of the file (informational)

// SACK datagram.
constexpr uint16_t kSackMagic = 0x4353;  // "CS"
constexpr size_t kSackHeaderSize = 28;   // see block_codec.h
constexpr size_t kSackRunSize = 8;       // start(4) length(4)
constexpr size_t kSackMaxRuns = (kMaxDatagram - kSackHeaderSize) / kSackRunSize;  // 140
constexpr uint8_t kSackFlagComplete = 0x01;  // every block of the file received

// Limits.
constexpr uint32_t kMaxFilesPerTransfer = 65535;  // 16-bit file index
constexpr uint64_t kMaxFileSize = static_cast<uint64_t>(kBlockPayloadSize) * 0xFFFFFFFFull;
constexpr size_t kMaxCtrlMessage = 16u * 1024u * 1024u;  // reassembled JSON size
constexpr size_t kCtrlChunk = 16 * 1024;  // one KCP message; well under the 128-fragment limit
constexpr int kKcpWindow = 1024;

// Timers (milliseconds).
constexpr int kSackIntervalMs = 60;
constexpr int kSackCompleteRepeatMs = 200;
constexpr int kRepairMinHoldMs = 120;   // do not resend a block sooner than this
constexpr int kPeerSilenceTimeoutMs = 30000;
constexpr int kProgressIntervalMs = 100;  // <= 10 Hz UI progress

}  // namespace ct

#endif  // CT_TRANSFER_PROTOCOL_H_
