/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "crosstransfer/ct_api.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

#include "api/core.h"

namespace {

struct Holder {
  std::unique_ptr<ct::Core> core;
};

const char* Dup(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (!out) return nullptr;
  std::memcpy(out, s.c_str(), s.size() + 1);
  return out;
}

bool ParseJson(const char* text, nlohmann::json* out, bool allow_null) {
  if (!text) {
    if (!allow_null) return false;
    *out = nlohmann::json::object();
    return true;
  }
  *out = nlohmann::json::parse(text, nullptr, false);
  return !out->is_discarded();
}

}  // namespace

struct CtCore {
  Holder h;
};

extern "C" {

CtCore* CtCreate(const char* config_json) {
  nlohmann::json cfg;
  if (!ParseJson(config_json, &cfg, false) || !cfg.is_object()) return nullptr;
  std::string err;
  auto core = ct::Core::Create(cfg, &err);
  if (!core) return nullptr;
  auto* handle = new CtCore;
  handle->h.core = std::move(core);
  return handle;
}

void CtDestroy(CtCore* core) { delete core; }

void CtSetEventCallback(CtCore* core, CtEventCallback cb, void* user_data) {
  if (!core) return;
  if (!cb) {
    core->h.core->SetEventCallback(nullptr);
    return;
  }
  core->h.core->SetEventCallback(
      [cb, user_data](const std::string& json) { cb(json.c_str(), user_data); });
}

int CtUpdateConfig(CtCore* core, const char* config_json) {
  if (!core) return CT_ERR_INVALID_ARG;
  nlohmann::json cfg;
  if (!ParseJson(config_json, &cfg, false) || !cfg.is_object()) return CT_ERR_INVALID_ARG;
  std::string err;
  return core->h.core->UpdateConfig(cfg, &err);
}

int CtShareCreate(CtCore* core, const char* paths_json, const char* options_json,
                  const char** out_share_id) {
  if (out_share_id) *out_share_id = nullptr;
  if (!core) return CT_ERR_INVALID_ARG;
  nlohmann::json paths, options;
  if (!ParseJson(paths_json, &paths, false) || !paths.is_array() || paths.empty()) {
    return CT_ERR_INVALID_ARG;
  }
  if (!ParseJson(options_json, &options, true) || !options.is_object()) return CT_ERR_INVALID_ARG;
  std::vector<std::string> list;
  for (const auto& p : paths) {
    if (!p.is_string()) return CT_ERR_INVALID_ARG;
    list.push_back(p.get<std::string>());
  }
  std::string id, err;
  const int rc = core->h.core->ShareCreate(list, options, &id, &err);
  if (rc == CT_OK && out_share_id) *out_share_id = Dup(id);
  return rc;
}

int CtShareClose(CtCore* core, const char* share_id) {
  if (!core || !share_id) return CT_ERR_INVALID_ARG;
  return core->h.core->ShareClose(share_id);
}

int CtReceiveStart(CtCore* core, const char* code_or_link, const char* save_dir,
                   const char** out_transfer_id) {
  if (out_transfer_id) *out_transfer_id = nullptr;
  if (!core || !code_or_link) return CT_ERR_INVALID_ARG;
  std::string id, err;
  const int rc = core->h.core->ReceiveStart(code_or_link, save_dir ? save_dir : "", &id, &err);
  if (rc == CT_OK && out_transfer_id) *out_transfer_id = Dup(id);
  return rc;
}

int CtReceiveResume(CtCore* core, const char* transfer_id) {
  if (!core || !transfer_id) return CT_ERR_INVALID_ARG;
  return core->h.core->ReceiveResume(transfer_id);
}

int CtTransferPause(CtCore* core, const char* transfer_id) {
  if (!core || !transfer_id) return CT_ERR_INVALID_ARG;
  return core->h.core->TransferPause(transfer_id);
}

int CtTransferResume(CtCore* core, const char* transfer_id) {
  if (!core || !transfer_id) return CT_ERR_INVALID_ARG;
  return core->h.core->TransferResume(transfer_id);
}

int CtTransferCancel(CtCore* core, const char* transfer_id) {
  if (!core || !transfer_id) return CT_ERR_INVALID_ARG;
  return core->h.core->TransferCancel(transfer_id);
}

const char* CtQuery(CtCore* core, const char* query_json) {
  if (!core) return nullptr;
  nlohmann::json q;
  if (!ParseJson(query_json, &q, true) || !q.is_object()) return nullptr;
  return Dup(core->h.core->Query(q.value("what", std::string("all"))));
}

void CtFreeString(const char* s) { std::free(const_cast<char*>(s)); }

const char* CtVersion(void) { return "0.1.0"; }

}  // extern "C"
