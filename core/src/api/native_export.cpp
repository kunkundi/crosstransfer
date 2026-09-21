/*
 * Anchor translation unit for the crosstransfer_native shared library. The
 * static archives are pulled in whole (-force_load / --whole-archive); this
 * file also hosts the small helpers that only the FFI consumer needs.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "crosstransfer/ct_api.h"

extern "C" CT_API const char* CtNativeVersion(void) { return CtVersion(); }

namespace {

// Dart's NativeCallable.listener delivers the call asynchronously, after the
// core has already released the JSON buffer. This sink hands the listener a
// heap copy instead; the receiver releases it with CtFreeString.
struct OwnedSink {
  CtEventCallback cb;
  void* user_data;
};

std::mutex g_sinks_mutex;
// Retained for the process lifetime: a callback may still be in flight when
// the sink is replaced, and an app installs at most a handful of sinks.
std::vector<std::unique_ptr<OwnedSink>> g_sinks;

void OwnedThunk(const char* json_utf8, void* ud) {
  auto* sink = static_cast<OwnedSink*>(ud);
  const char* text = json_utf8 ? json_utf8 : "";
  const size_t size = std::strlen(text) + 1;
  char* copy = static_cast<char*>(std::malloc(size));
  if (!copy) return;
  std::memcpy(copy, text, size);
  sink->cb(copy, sink->user_data);
}

}  // namespace

extern "C" {

/**
 * Like CtSetEventCallback, but each event is delivered as a malloc'd copy that
 * outlives the call; the callback must release it with CtFreeString.
 */
CT_API void CtSetEventCallbackOwned(CtCore* core, CtEventCallback cb, void* user_data) {
  if (!core) return;
  if (!cb) {
    CtSetEventCallback(core, nullptr, nullptr);
    return;
  }
  auto sink = std::make_unique<OwnedSink>(OwnedSink{cb, user_data});
  OwnedSink* raw = sink.get();
  {
    std::lock_guard<std::mutex> lock(g_sinks_mutex);
    g_sinks.push_back(std::move(sink));
  }
  CtSetEventCallback(core, &OwnedThunk, raw);
}

}  // extern "C"
