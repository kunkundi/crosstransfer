/*
 * CrossTransfer core — transfer manifest.
 *
 * The manifest lists every file (relative '/'-separated path + size) and
 * every directory (including empty ones) of a share, plus the top-level
 * entries ("roots") the receiver places under its save directory. Hashes
 * are not part of the manifest: the sender computes SHA-256 while sweeping
 * each file and sends it in `file_done`.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_MANIFEST_H_
#define CT_TRANSFER_MANIFEST_H_

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

namespace ct {

struct ManifestFile {
  std::string path;  // relative, '/'-separated, starts with a root name
  uint64_t size = 0;
};

struct ManifestRoot {
  std::string name;  // single path component
  bool is_dir = false;
};

struct Manifest {
  std::vector<ManifestFile> files;
  std::vector<std::string> dirs;  // every directory, parents before children
  std::vector<ManifestRoot> roots;
  uint64_t total_bytes = 0;

  nlohmann::json ToJson() const;
  // Parses and validates (safe paths, no duplicates, sizes and counts within
  // protocol limits, roots consistent with entries). Returns false and sets
  // *error on failure.
  static bool FromJson(const nlohmann::json& j, Manifest* out, std::string* error);
};

// Number of data blocks for a file of `size` bytes (0 for an empty file).
uint32_t BlockCountFor(uint64_t size);
// Payload length of block `index` of a file with `size` bytes.
uint16_t BlockLenFor(uint64_t size, uint32_t index);

// Walks the given absolute paths (files or directories). Fills the manifest
// and, parallel to manifest.files, the absolute path of each file. Symlinks
// are skipped. Duplicate root names or unsafe names fail.
bool BuildManifest(const std::vector<std::string>& abs_paths, Manifest* out,
                   std::vector<std::filesystem::path>* abs_files, std::string* error);

}  // namespace ct

#endif  // CT_TRANSFER_MANIFEST_H_
