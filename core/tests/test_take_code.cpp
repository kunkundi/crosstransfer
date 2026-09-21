#include <doctest/doctest.h>

#include "share/take_code.h"

using namespace ct::takecode;

TEST_CASE("normalize accepted spellings") {
  CHECK(Normalize("3K7QWP9X2M") == "3K7QWP9X2M");
  CHECK(Normalize("3k7qw-p9x2m") == "3K7QWP9X2M");
  CHECK(Normalize("3K7QW P9X2M") == "3K7QWP9X2M");
  CHECK(Normalize("3K7QW_P9X2M") == "3K7QWP9X2M");
  CHECK(Normalize("OI7LW-P9X2M") == "0171WP9X2M");  // O->0, I/L->1
}

TEST_CASE("normalize rejections") {
  CHECK(Normalize("") == "");
  CHECK(Normalize("3K7QWP9X2") == "");      // 9 symbols
  CHECK(Normalize("3K7QWP9X2MA") == "");    // 11 symbols
  CHECK(Normalize("3K7QWP9X2U") == "");     // U not in alphabet
  CHECK(Normalize("3K7QWP9X2\xC3\xA9") == "");
  CHECK(Normalize("3K7QW.P9X2M") == "");    // '.' not a separator
}

TEST_CASE("format and links") {
  CHECK(Format("3K7QWP9X2M") == "3K7QW-P9X2M");
  CHECK(Format("abc") == "abc");
  CHECK(MakeHttpsLink("example.com", "3K7QWP9X2M") == "https://example.com/r/3K7QW-P9X2M");
  CHECK(MakeHttpsLink("", "3K7QWP9X2M") == "");
  CHECK(MakeSchemeLink("3K7QWP9X2M") == "crosstransfer://r/3K7QW-P9X2M");
  CHECK(LogPrefix("3K7QWP9X2M") == "3K7Q******");
  CHECK(LogPrefix("3K") == "????******");
}

TEST_CASE("parse code or link") {
  CHECK(ParseCodeOrLink("  3k7qw-p9x2m \n") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("https://example.com/r/3K7QW-P9X2M") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("https://example.com/r/3K7QW-P9X2M?utm=1#x") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("http://example.com/r/3k7qwp9x2m/") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("crosstransfer://r/3K7QW-P9X2M") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("CrossTransfer:r/3K7QW-P9X2M") == "3K7QWP9X2M");
  CHECK(ParseCodeOrLink("https://example.com/other/3K7QW-P9X2M") == "");
  CHECK(ParseCodeOrLink("https://example.com/r/") == "");
  CHECK(ParseCodeOrLink("crosstransfer://") == "");
  CHECK(ParseCodeOrLink("") == "");
}
