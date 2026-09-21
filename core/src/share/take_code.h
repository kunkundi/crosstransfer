/*
 * CrossTransfer core — take-code and link encoding.
 *
 * Codes are 10 Crockford Base32 symbols (no I, L, O, U), displayed as
 * XXXXX-XXXXX. Input normalisation mirrors server/internal/codes.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_SHARE_TAKE_CODE_H_
#define CT_SHARE_TAKE_CODE_H_

#include <cstdint>
#include <string>
#include <string_view>

namespace ct {
namespace takecode {

constexpr const char* kAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
constexpr size_t kLength = 10;
constexpr size_t kPrefixLength = 4;
constexpr const char* kScheme = "crosstransfer";

// Strips '-', ' ', '\t', '_', upper-cases, maps O->0 and I/L->1, validates the
// alphabet and length. Returns the canonical 10-symbol code or "" on failure.
std::string Normalize(std::string_view input);

// Canonical -> "XXXXX-XXXXX". Non-canonical input is returned unchanged.
std::string Format(std::string_view canonical);

// Accepts a bare code (any spelling), "https://<host>/r/<code>[?...][#...]",
// "http://...", "crosstransfer://r/<code>" or "crosstransfer:r/<code>", with
// surrounding whitespace. Returns the canonical code or "".
std::string ParseCodeOrLink(std::string_view input);

// "https://<link_host>/r/XXXXX-XXXXX"; empty link_host yields "".
std::string MakeHttpsLink(std::string_view link_host, std::string_view canonical);
// "crosstransfer://r/XXXXX-XXXXX"
std::string MakeSchemeLink(std::string_view canonical);

// First 4 symbols + "******" for logs (never log full codes).
std::string LogPrefix(std::string_view canonical);

}  // namespace takecode
}  // namespace ct

#endif  // CT_SHARE_TAKE_CODE_H_
