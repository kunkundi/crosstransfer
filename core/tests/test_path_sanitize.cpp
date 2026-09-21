#include <doctest/doctest.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "transfer/path_sanitize.h"

using namespace ct::paths;

TEST_CASE("safe relative paths") {
  CHECK(IsSafeRelativePath("a"));
  CHECK(IsSafeRelativePath("a/b/c.txt"));
  CHECK(IsSafeRelativePath("\xE6\x96\x87\xE4\xBB\xB6/\xE5\x9B\xBE\xE7\x89\x87.png"));
  CHECK(IsSafeRelativePath("a b.txt"));
  CHECK(IsSafeRelativePath("con_x.txt"));
  CHECK(IsSafeRelativePath("console.txt"));
  CHECK(IsSafeRelativePath(".hidden"));
  CHECK(IsSafeRelativePath("a..b"));
}

TEST_CASE("unsafe relative paths") {
  CHECK_FALSE(IsSafeRelativePath(""));
  CHECK_FALSE(IsSafeRelativePath("/abs"));
  CHECK_FALSE(IsSafeRelativePath("a\\b"));
  CHECK_FALSE(IsSafeRelativePath("C:/x"));
  CHECK_FALSE(IsSafeRelativePath("C:x"));
  CHECK_FALSE(IsSafeRelativePath("//server/share"));
  CHECK_FALSE(IsSafeRelativePath("."));
  CHECK_FALSE(IsSafeRelativePath(".."));
  CHECK_FALSE(IsSafeRelativePath("a/../b"));
  CHECK_FALSE(IsSafeRelativePath("a/./b"));
  CHECK_FALSE(IsSafeRelativePath("a//b"));
  CHECK_FALSE(IsSafeRelativePath("a/"));
  CHECK_FALSE(IsSafeRelativePath("a\x01"));
  CHECK_FALSE(IsSafeRelativePath("a\x7f"));
  CHECK_FALSE(IsSafeRelativePath("a\n"));
  CHECK_FALSE(IsSafeRelativePath("a "));
  CHECK_FALSE(IsSafeRelativePath("a."));
  CHECK_FALSE(IsSafeRelativePath("dir /x"));
  CHECK_FALSE(IsSafeRelativePath("CON"));
  CHECK_FALSE(IsSafeRelativePath("con.txt"));
  CHECK_FALSE(IsSafeRelativePath("x/Nul"));
  CHECK_FALSE(IsSafeRelativePath("COM1"));
  CHECK_FALSE(IsSafeRelativePath("lpt9.log"));
  CHECK_FALSE(IsSafeRelativePath("a:b"));
  CHECK_FALSE(IsSafeRelativePath("a*b"));
  CHECK_FALSE(IsSafeRelativePath("a?b"));
  CHECK_FALSE(IsSafeRelativePath("a\"b"));
  CHECK_FALSE(IsSafeRelativePath("a<b"));
  CHECK_FALSE(IsSafeRelativePath("a>b"));
  CHECK_FALSE(IsSafeRelativePath("a|b"));
  CHECK_FALSE(IsSafeRelativePath("\xC0\xAF"));          // overlong
  CHECK_FALSE(IsSafeRelativePath("\xED\xA0\x80"));      // surrogate
  CHECK_FALSE(IsSafeRelativePath("\xFF"));
  CHECK_FALSE(IsSafeRelativePath(std::string(256, 'a')));
  CHECK(IsSafeRelativePath(std::string(255, 'a')));
  std::string longpath;
  for (int i = 0; i < 41; ++i) longpath += std::string(100, 'b') + "/";  // 4141 bytes
  longpath += "x";
  CHECK_FALSE(IsSafeRelativePath(longpath));
  std::string okpath;
  for (int i = 0; i < 40; ++i) okpath += std::string(100, 'b') + "/";  // 4041 bytes
  okpath += "x";
  CHECK(IsSafeRelativePath(okpath));
}

TEST_CASE("join and basename") {
  const auto joined = JoinSafe(std::filesystem::path("/base"), "a/b/c.txt");
  CHECK(ToUtf8(joined) == std::string("/base") + static_cast<char>(std::filesystem::path::preferred_separator) +
                              "a" + static_cast<char>(std::filesystem::path::preferred_separator) + "b" +
                              static_cast<char>(std::filesystem::path::preferred_separator) + "c.txt");
  CHECK(BaseName("a/b/c.txt") == "c.txt");
  CHECK(BaseName("c.txt") == "c.txt");
  CHECK(ToUtf8(FromUtf8("\xE6\x96\x87")) == "\xE6\x96\x87");
}

TEST_CASE("unique name") {
  const auto dir = std::filesystem::temp_directory_path() / "ct_unique_test";
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir);
  CHECK(UniqueName(dir, "a.txt", false) == "a.txt");
  std::ofstream(dir / "a.txt") << "x";
  CHECK(UniqueName(dir, "a.txt", false) == "a (1).txt");
  std::ofstream(dir / "a (1).txt") << "x";
  CHECK(UniqueName(dir, "a.txt", false) == "a (2).txt");
  std::filesystem::create_directories(dir / "d");
  CHECK(UniqueName(dir, "d", true) == "d (1)");
  std::ofstream(dir / "noext") << "x";
  CHECK(UniqueName(dir, "noext", false) == "noext (1)");
  std::ofstream(dir / ".hidden") << "x";
  CHECK(UniqueName(dir, ".hidden", false) == ".hidden (1)");
  std::filesystem::remove_all(dir);
}
