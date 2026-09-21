/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/path_sanitize.h"

#include <cctype>
#include <random>
#include <string>
#include <system_error>

namespace ct {
namespace paths {
namespace {

bool ValidUtf8(std::string_view s) {
  size_t i = 0;
  const size_t n = s.size();
  while (i < n) {
    const unsigned char c = static_cast<unsigned char>(s[i]);
    if (c < 0x80) {
      ++i;
      continue;
    }
    size_t len;
    uint32_t cp;
    if ((c & 0xE0) == 0xC0) {
      len = 2;
      cp = c & 0x1F;
      if (c < 0xC2) return false;  // overlong 2-byte
    } else if ((c & 0xF0) == 0xE0) {
      len = 3;
      cp = c & 0x0F;
    } else if ((c & 0xF8) == 0xF0) {
      len = 4;
      cp = c & 0x07;
      if (c > 0xF4) return false;
    } else {
      return false;
    }
    if (i + len > n) return false;
    for (size_t k = 1; k < len; ++k) {
      const unsigned char cc = static_cast<unsigned char>(s[i + k]);
      if ((cc & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (len == 3 && cp < 0x800) return false;      // overlong
    if (len == 4 && cp < 0x10000) return false;    // overlong
    if (cp > 0x10FFFF) return false;
    if (cp >= 0xD800 && cp <= 0xDFFF) return false;  // surrogates
    i += len;
  }
  return true;
}

bool IsReservedDeviceName(std::string_view component) {
  // Strip the extension (everything from the first '.').
  std::string_view stem = component.substr(0, component.find('.'));
  if (stem.empty()) return false;
  std::string up;
  up.reserve(stem.size());
  for (char c : stem) up.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
  if (up == "CON" || up == "PRN" || up == "AUX" || up == "NUL") return true;
  if (up.size() == 4 && (up.compare(0, 3, "COM") == 0 || up.compare(0, 3, "LPT") == 0) &&
      up[3] >= '1' && up[3] <= '9') {
    return true;
  }
  return false;
}

bool SafeComponent(std::string_view c) {
  if (c.empty() || c == "." || c == "..") return false;
  if (c.size() > kMaxComponentBytes) return false;
  for (char ch : c) {
    const unsigned char u = static_cast<unsigned char>(ch);
    if (u < 0x20 || u == 0x7F) return false;
    switch (ch) {
      case '\\': case ':': case '*': case '?': case '"': case '<': case '>': case '|':
        return false;
      default:
        break;
    }
  }
  if (c.back() == ' ' || c.back() == '.') return false;
  if (IsReservedDeviceName(c)) return false;
  return true;
}

}  // namespace

bool IsSafeRelativePath(std::string_view rel) {
  if (rel.empty() || rel.size() > kMaxPathBytes) return false;
  if (rel.front() == '/') return false;
  if (!ValidUtf8(rel)) return false;
  size_t start = 0;
  while (start <= rel.size()) {
    const size_t slash = rel.find('/', start);
    const std::string_view comp =
        rel.substr(start, slash == std::string_view::npos ? std::string_view::npos : slash - start);
    if (!SafeComponent(comp)) return false;
    if (slash == std::string_view::npos) break;
    start = slash + 1;
    if (start == rel.size()) return false;  // trailing '/'
  }
  return true;
}

std::filesystem::path JoinSafe(const std::filesystem::path& base, std::string_view rel) {
  std::filesystem::path out = base;
  size_t start = 0;
  while (start < rel.size()) {
    const size_t slash = rel.find('/', start);
    const std::string_view comp =
        rel.substr(start, slash == std::string_view::npos ? std::string_view::npos : slash - start);
    if (!comp.empty()) out /= FromUtf8(comp);
    if (slash == std::string_view::npos) break;
    start = slash + 1;
  }
  return out;
}

std::string UniqueName(const std::filesystem::path& base, std::string_view name, bool is_dir) {
  std::error_code ec;
  auto exists = [&](const std::string& n) {
    return std::filesystem::exists(base / FromUtf8(n), ec);
  };
  std::string candidate(name);
  if (!exists(candidate)) return candidate;
  std::string stem(name), ext;
  if (!is_dir) {
    const size_t dot = name.rfind('.');
    if (dot != std::string_view::npos && dot > 0) {
      stem = std::string(name.substr(0, dot));
      ext = std::string(name.substr(dot));
    }
  }
  for (int i = 1; i <= 10000; ++i) {
    candidate = stem + " (" + std::to_string(i) + ")" + ext;
    if (!exists(candidate)) return candidate;
  }
  std::random_device rd;
  candidate = stem + " (" + std::to_string(rd()) + ")" + ext;
  return candidate;
}

std::string ToUtf8(const std::filesystem::path& p) {
#ifdef _WIN32
  const std::u8string u8 = p.u8string();
  return std::string(u8.begin(), u8.end());
#else
  return p.string();
#endif
}

std::filesystem::path FromUtf8(std::string_view s) {
#ifdef _WIN32
  return std::filesystem::u8path(s.begin(), s.end());
#else
  return std::filesystem::path(std::string(s));
#endif
}

std::string_view BaseName(std::string_view rel) {
  const size_t slash = rel.rfind('/');
  return slash == std::string_view::npos ? rel : rel.substr(slash + 1);
}

}  // namespace paths
}  // namespace ct
