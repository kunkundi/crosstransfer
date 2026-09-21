/*
 * CrossTransfer core — persistent state: config.json and transfers.json.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_STORAGE_STORAGE_H_
#define CT_STORAGE_STORAGE_H_

#include <filesystem>
#include <string>

#include <nlohmann/json.hpp>

namespace ct {

class Storage {
 public:
  explicit Storage(std::filesystem::path data_dir);

  const std::filesystem::path& data_dir() const { return data_dir_; }
  bool EnsureDataDir(std::string* error);

  // config.json: object; missing file -> empty object.
  nlohmann::json LoadConfig();
  bool SaveConfig(const nlohmann::json& config, std::string* error);

  // transfers.json: {"receives": [ ... ]}; missing file -> empty array.
  nlohmann::json LoadReceives();
  bool SaveReceives(const nlohmann::json& receives, std::string* error);

 private:
  nlohmann::json LoadJson(const std::filesystem::path& p);
  bool SaveJson(const std::filesystem::path& p, const nlohmann::json& j, std::string* error);

  std::filesystem::path data_dir_;
};

}  // namespace ct

#endif  // CT_STORAGE_STORAGE_H_
