/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "storage/storage.h"

#include "log/log.h"
#include "transfer/file_io.h"

namespace ct {

Storage::Storage(std::filesystem::path data_dir) : data_dir_(std::move(data_dir)) {}

bool Storage::EnsureDataDir(std::string* error) { return EnsureDir(data_dir_, error); }

nlohmann::json Storage::LoadJson(const std::filesystem::path& p) {
  std::string text;
  if (!ReadFileToString(p, &text)) return nullptr;
  nlohmann::json j = nlohmann::json::parse(text, nullptr, false);
  if (j.is_discarded()) {
    CT_LOG_WARN("ignoring corrupt {}", p.string());
    return nullptr;
  }
  return j;
}

bool Storage::SaveJson(const std::filesystem::path& p, const nlohmann::json& j,
                       std::string* error) {
  if (!EnsureDir(data_dir_, error)) return false;
  return WriteFileAtomic(p, j.dump(2), error);
}

nlohmann::json Storage::LoadConfig() {
  nlohmann::json j = LoadJson(data_dir_ / "config.json");
  return j.is_object() ? j : nlohmann::json::object();
}

bool Storage::SaveConfig(const nlohmann::json& config, std::string* error) {
  return SaveJson(data_dir_ / "config.json", config, error);
}

nlohmann::json Storage::LoadReceives() {
  nlohmann::json j = LoadJson(data_dir_ / "transfers.json");
  if (j.is_object() && j.contains("receives") && j["receives"].is_array()) return j["receives"];
  return nlohmann::json::array();
}

bool Storage::SaveReceives(const nlohmann::json& receives, std::string* error) {
  return SaveJson(data_dir_ / "transfers.json", {{"version", 1}, {"receives", receives}}, error);
}

}  // namespace ct
