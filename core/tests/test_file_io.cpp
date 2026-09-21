#include <cstdint>
#include <doctest/doctest.h>

#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "transfer/file_io.h"
#include "transfer/sha256.h"

using namespace ct;

TEST_CASE("sha256 vectors") {
  CHECK(Sha256Hex("abc", 3) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK(Sha256Hex("", 0) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  Sha256 h;
  h.Update("a", 1);
  h.Update("bc", 2);
  CHECK(h.FinishHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK(h.FinishHex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");  // reset
}

TEST_CASE("file io round trip and sha256 file") {
  const auto dir = std::filesystem::temp_directory_path() / "ct_file_io_test";
  std::filesystem::remove_all(dir);
  REQUIRE(EnsureDir(dir / "sub"));
  const auto path = dir / "sub" / "part.bin";

  FileWriter w;
  REQUIRE(w.Open(path));
  REQUIRE(w.EnsureSize(3 * 1024 * 1024));
  std::vector<uint8_t> chunk(1100);
  for (size_t i = 0; i < chunk.size(); ++i) chunk[i] = static_cast<uint8_t>(i);
  REQUIRE(w.WriteAt(2200, chunk.data(), chunk.size()));
  REQUIRE(w.WriteAt(0, chunk.data(), chunk.size()));
  REQUIRE(w.Flush());
  w.Close();
  CHECK(std::filesystem::file_size(path) == 3 * 1024 * 1024);

  // Re-open must not truncate.
  REQUIRE(w.Open(path));
  REQUIRE(w.WriteAt(1100, chunk.data(), chunk.size()));
  w.Close();
  CHECK(std::filesystem::file_size(path) == 3 * 1024 * 1024);

  FileReader r;
  REQUIRE(r.Open(path));
  CHECK(r.Size() == 3 * 1024 * 1024);
  std::vector<uint8_t> buf(3300);
  size_t got = 0;
  REQUIRE(r.ReadAt(0, buf.data(), buf.size(), &got));
  CHECK(got == 3300);
  CHECK(std::memcmp(buf.data(), chunk.data(), 1100) == 0);
  CHECK(std::memcmp(buf.data() + 1100, chunk.data(), 1100) == 0);
  CHECK(std::memcmp(buf.data() + 2200, chunk.data(), 1100) == 0);
  REQUIRE(r.ReadAt(3 * 1024 * 1024 - 10, buf.data(), 100, &got));
  CHECK(got == 10);  // short read at EOF
  REQUIRE(r.ReadAt(3 * 1024 * 1024 + 5, buf.data(), 100, &got));
  CHECK(got == 0);
  r.Close();

  std::string hex;
  REQUIRE(Sha256File(path, &hex));
  CHECK(hex.size() == 64);
  int polls = 0;
  CHECK_FALSE(Sha256File(path, &hex, [&] { return ++polls > 0; }));  // cancelled

  const auto small = dir / "small.txt";
  REQUIRE(WriteFileAtomic(small, "hello"));
  std::string content;
  REQUIRE(ReadFileToString(small, &content));
  CHECK(content == "hello");
  REQUIRE(WriteFileAtomic(small, "world"));
  REQUIRE(ReadFileToString(small, &content));
  CHECK(content == "world");
  CHECK_FALSE(std::filesystem::exists(dir / "small.txt.tmp"));
  REQUIRE(Sha256File(small, &hex));
  CHECK(hex == Sha256Hex("world", 5));

  const auto empty = dir / "empty";
  REQUIRE(CreateEmptyFile(empty));
  CHECK(std::filesystem::file_size(empty) == 0);
  REQUIRE(RenameReplace(empty, small));
  CHECK(std::filesystem::file_size(small) == 0);
  CHECK_FALSE(std::filesystem::exists(empty));
  CHECK(FreeSpace(dir) > 0);
  CHECK_FALSE(r.Open(dir / "missing"));
  std::filesystem::remove_all(dir);
}
