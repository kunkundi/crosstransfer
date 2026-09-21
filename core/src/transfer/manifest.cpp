/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/manifest.h"

#include <algorithm>
#include <set>
#include <system_error>

#include "transfer/path_sanitize.h"
#include "transfer/protocol.h"

namespace ct {

uint32_t BlockCountFor(uint64_t size) {
  if (size == 0) return 0;
  return static_cast<uint32_t>((size + kBlockPayloadSize - 1) / kBlockPayloadSize);
}

uint16_t BlockLenFor(uint64_t size, uint32_t index) {
  const uint64_t offset = static_cast<uint64_t>(index) * kBlockPayloadSize;
  if (offset >= size) return 0;
  const uint64_t remain = size - offset;
  return static_cast<uint16_t>(remain < kBlockPayloadSize ? remain : kBlockPayloadSize);
}

nlohmann::json Manifest::ToJson() const {
  nlohmann::json files = nlohmann::json::array();
  for (const auto& f : this->files) files.push_back({{"path", f.path}, {"size", f.size}});
  nlohmann::json roots = nlohmann::json::array();
  for (const auto& r : this->roots) roots.push_back({{"name", r.name}, {"dir", r.is_dir}});
  return {{"files", files}, {"dirs", dirs}, {"roots", roots}, {"total_bytes", total_bytes}};
}

bool Manifest::FromJson(const nlohmann::json& j, Manifest* out, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    return false;
  };
  if (!j.is_object()) return fail("manifest not an object");
  const auto files = j.find("files");
  const auto dirs = j.find("dirs");
  const auto roots = j.find("roots");
  if (files == j.end() || !files->is_array()) return fail("manifest.files missing");
  if (dirs != j.end() && !dirs->is_array()) return fail("manifest.dirs invalid");
  if (roots == j.end() || !roots->is_array()) return fail("manifest.roots missing");
  if (files->size() > kMaxFilesPerTransfer) return fail("too many files");

  Manifest m;
  std::set<std::string> seen;
  std::set<std::string> root_names;
  for (const auto& r : *roots) {
    if (!r.is_object() || !r.contains("name") || !r["name"].is_string()) {
      return fail("manifest.roots entry invalid");
    }
    ManifestRoot root;
    root.name = r["name"].get<std::string>();
    root.is_dir = r.value("dir", false);
    if (!paths::IsSafeRelativePath(root.name) || root.name.find('/') != std::string::npos) {
      return fail("manifest root name unsafe");
    }
    if (!root_names.insert(root.name).second) return fail("duplicate root");
    m.roots.push_back(root);
  }
  auto root_of = [](const std::string& p) { return p.substr(0, p.find('/')); };
  if (dirs != j.end()) {
    for (const auto& d : *dirs) {
      if (!d.is_string()) return fail("manifest.dirs entry invalid");
      const std::string p = d.get<std::string>();
      if (!paths::IsSafeRelativePath(p)) return fail("manifest dir path unsafe");
      if (!seen.insert(p).second) return fail("duplicate manifest entry");
      if (!root_names.count(root_of(p))) return fail("manifest dir outside roots");
      m.dirs.push_back(p);
    }
  }
  uint64_t total = 0;
  for (const auto& f : *files) {
    if (!f.is_object() || !f.contains("path") || !f["path"].is_string() ||
        !f.contains("size") || !f["size"].is_number_unsigned()) {
      return fail("manifest.files entry invalid");
    }
    ManifestFile mf;
    mf.path = f["path"].get<std::string>();
    mf.size = f["size"].get<uint64_t>();
    if (!paths::IsSafeRelativePath(mf.path)) return fail("manifest file path unsafe");
    if (mf.size > kMaxFileSize) return fail("file too large");
    if (!seen.insert(mf.path).second) return fail("duplicate manifest entry");
    if (!root_names.count(root_of(mf.path))) return fail("manifest file outside roots");
    total += mf.size;
    if (total < mf.size) return fail("total size overflow");
    m.files.push_back(std::move(mf));
  }
  // A file must not be nested inside another file, and a directory root must
  // not also be a file path.
  for (const auto& f : m.files) {
    std::string prefix = f.path + "/";
    for (const auto& d : m.dirs) {
      if (d.compare(0, prefix.size(), prefix) == 0) return fail("directory nested in file");
    }
    for (const auto& r : m.roots) {
      if (r.is_dir && r.name == f.path) return fail("root type mismatch");
    }
  }
  m.total_bytes = total;
  *out = std::move(m);
  return true;
}

bool BuildManifest(const std::vector<std::string>& abs_paths, Manifest* out,
                   std::vector<std::filesystem::path>* abs_files, std::string* error) {
  auto fail = [&](const std::string& msg) {
    if (error) *error = msg;
    return false;
  };
  Manifest m;
  std::vector<std::filesystem::path> files;
  std::set<std::string> root_names;
  std::error_code ec;
  for (const auto& raw : abs_paths) {
    const std::filesystem::path p = paths::FromUtf8(raw);
    const auto st = std::filesystem::symlink_status(p, ec);
    if (ec) return fail("cannot stat " + raw + ": " + ec.message());
    if (std::filesystem::is_symlink(st)) return fail("symlink not supported: " + raw);
    const std::string name = paths::ToUtf8(p.filename());
    if (name.empty() || !paths::IsSafeRelativePath(name) || name.find('/') != std::string::npos) {
      return fail("unsafe name: " + name);
    }
    if (!root_names.insert(name).second) return fail("duplicate name: " + name);
    if (std::filesystem::is_regular_file(st)) {
      const uint64_t size = std::filesystem::file_size(p, ec);
      if (ec) return fail("cannot size " + raw);
      if (size > kMaxFileSize) return fail("file too large: " + raw);
      m.roots.push_back({name, false});
      m.files.push_back({name, size});
      files.push_back(p);
      m.total_bytes += size;
    } else if (std::filesystem::is_directory(st)) {
      m.roots.push_back({name, true});
      m.dirs.push_back(name);
      std::filesystem::recursive_directory_iterator it(
          p, std::filesystem::directory_options::skip_permission_denied, ec);
      if (ec) return fail("cannot list " + raw + ": " + ec.message());
      for (const auto& entry : it) {
        const auto est = entry.symlink_status(ec);
        if (ec) continue;
        if (std::filesystem::is_symlink(est)) {
          it.disable_recursion_pending();
          continue;
        }
        const std::filesystem::path rel_fs = std::filesystem::relative(entry.path(), p.parent_path(), ec);
        if (ec) return fail("relative path failed");
        // Build a '/'-separated relative path from components.
        std::string rel;
        for (const auto& comp : rel_fs) {
          if (!rel.empty()) rel.push_back('/');
          rel += paths::ToUtf8(comp);
        }
        if (!paths::IsSafeRelativePath(rel)) return fail("unsafe path: " + rel);
        if (std::filesystem::is_directory(est)) {
          m.dirs.push_back(rel);
        } else if (std::filesystem::is_regular_file(est)) {
          const uint64_t size = std::filesystem::file_size(entry.path(), ec);
          if (ec) return fail("cannot size " + rel);
          if (size > kMaxFileSize) return fail("file too large: " + rel);
          if (m.files.size() >= kMaxFilesPerTransfer) return fail("too many files");
          m.files.push_back({rel, size});
          files.push_back(entry.path());
          m.total_bytes += size;
        }
      }
    } else {
      return fail("not a file or directory: " + raw);
    }
    if (m.files.size() > kMaxFilesPerTransfer) return fail("too many files");
  }
  if (m.roots.empty()) return fail("nothing to share");
  std::sort(m.dirs.begin(), m.dirs.end());
  *out = std::move(m);
  if (abs_files) *abs_files = std::move(files);
  return true;
}

}  // namespace ct
