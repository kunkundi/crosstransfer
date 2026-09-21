/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "share/take_code.h"

#include <array>
#include <cctype>

namespace ct {
namespace takecode {
namespace {

const std::array<int8_t, 256>& DecodeTable() {
  static const std::array<int8_t, 256> table = [] {
    std::array<int8_t, 256> t{};
    t.fill(-1);
    for (int i = 0; kAlphabet[i]; ++i) {
      t[static_cast<uint8_t>(kAlphabet[i])] = static_cast<int8_t>(i);
    }
    t['O'] = t['0'];
    t['I'] = t['1'];
    t['L'] = t['1'];
    return t;
  }();
  return table;
}

std::string_view Trim(std::string_view s) {
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) {
    s.remove_prefix(1);
  }
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) {
    s.remove_suffix(1);
  }
  return s;
}

bool IEquals(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(a[i])) !=
        std::tolower(static_cast<unsigned char>(b[i]))) {
      return false;
    }
  }
  return true;
}

}  // namespace

std::string Normalize(std::string_view input) {
  std::string out;
  out.reserve(kLength);
  const auto& table = DecodeTable();
  for (char ch : input) {
    unsigned char c = static_cast<unsigned char>(ch);
    if (c == '-' || c == ' ' || c == '\t' || c == '_') continue;
    if (c >= 'a' && c <= 'z') c = static_cast<unsigned char>(c - 'a' + 'A');
    if (c >= 0x80) return "";
    const int8_t idx = table[c];
    if (idx < 0) return "";
    if (out.size() >= kLength) return "";
    out.push_back(kAlphabet[idx]);
  }
  if (out.size() != kLength) return "";
  return out;
}

std::string Format(std::string_view canonical) {
  if (canonical.size() != kLength) return std::string(canonical);
  std::string out(canonical.substr(0, 5));
  out.push_back('-');
  out.append(canonical.substr(5));
  return out;
}

std::string ParseCodeOrLink(std::string_view input) {
  std::string_view s = Trim(input);
  if (s.empty()) return "";
  std::string_view rest;
  const size_t scheme_sep = s.find("://");
  const std::string_view scheme_prefix = "crosstransfer:";
  if (scheme_sep != std::string_view::npos) {
    rest = s.substr(scheme_sep + 3);
  } else if (s.size() > scheme_prefix.size() &&
             IEquals(s.substr(0, scheme_prefix.size()), scheme_prefix)) {
    rest = s.substr(scheme_prefix.size());
  } else {
    return Normalize(s);
  }
  // rest: "<host>/r/<code>..." or "r/<code>..." or "/r/<code>...".
  size_t r = rest.find("/r/");
  if (r != std::string_view::npos) {
    rest = rest.substr(r + 3);
  } else if (rest.size() > 2 && (rest[0] == 'r' || rest[0] == 'R') && rest[1] == '/') {
    rest = rest.substr(2);
  } else {
    return "";
  }
  const size_t end = rest.find_first_of("?#/");
  if (end != std::string_view::npos) rest = rest.substr(0, end);
  return Normalize(rest);
}

std::string MakeHttpsLink(std::string_view link_host, std::string_view canonical) {
  if (link_host.empty() || canonical.size() != kLength) return "";
  std::string out = "https://";
  out.append(link_host);
  out.append("/r/");
  out.append(Format(canonical));
  return out;
}

std::string MakeSchemeLink(std::string_view canonical) {
  if (canonical.size() != kLength) return "";
  std::string out = kScheme;
  out.append("://r/");
  out.append(Format(canonical));
  return out;
}

std::string LogPrefix(std::string_view canonical) {
  if (canonical.size() < kPrefixLength) return "????******";
  std::string out(canonical.substr(0, kPrefixLength));
  out.append("******");
  return out;
}

}  // namespace takecode
}  // namespace ct
