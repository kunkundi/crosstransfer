/*
 * CrossTransfer core — relative path validation and filesystem path helpers.
 *
 * Manifest paths are '/'-separated UTF-8 relative paths. They are produced by
 * the sender and must be treated as hostile by the receiver.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_PATH_SANITIZE_H_
#define CT_TRANSFER_PATH_SANITIZE_H_

#include <filesystem>
#include <string>
#include <string_view>

namespace ct {
namespace paths {

constexpr size_t kMaxComponentBytes = 255;
constexpr size_t kMaxPathBytes = 4096;

// True when `rel` is safe to join under a save directory on every platform:
// non-empty, no leading '/', no '\\', no drive or UNC prefix ("C:", "//"), no
// "." or ".." component, no empty component, no control characters (< 0x20,
// 0x7f), no component ending in ' ' or '.', no Windows reserved device name
// (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without extension, any case),
// no ':' '*' '?' '"' '<' '>' '|', valid UTF-8, component <= 255 bytes,
// total <= 4096 bytes.
bool IsSafeRelativePath(std::string_view rel);

// Joins a validated relative path under base using the platform separator.
std::filesystem::path JoinSafe(const std::filesystem::path& base,
                               std::string_view rel);

// Returns `name` if base/name does not exist, otherwise "name (1)",
// "name (2)", ... For files (is_dir == false) the suffix goes before the
// extension: "a (1).txt". `name` is a single component.
std::string UniqueName(const std::filesystem::path& base, std::string_view name,
                       bool is_dir);

// UTF-8 <-> std::filesystem::path (wide on Windows).
std::string ToUtf8(const std::filesystem::path& p);
std::filesystem::path FromUtf8(std::string_view s);

// Last component of a '/'-separated relative path.
std::string_view BaseName(std::string_view rel);

}  // namespace paths
}  // namespace ct

#endif  // CT_TRANSFER_PATH_SANITIZE_H_
