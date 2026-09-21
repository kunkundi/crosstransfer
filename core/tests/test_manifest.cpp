#include <cstdint>
#include <doctest/doctest.h>

#include <filesystem>
#include <fstream>
#include <string>

#include "transfer/ctrl_codec.h"
#include "transfer/manifest.h"
#include "transfer/protocol.h"

using namespace ct;

TEST_CASE("ctrl split and reassemble") {
  std::string small = R"({"type":"ping"})";
  auto chunks = SplitCtrlMessage(small);
  REQUIRE(chunks.size() == 1);
  CHECK(chunks[0][0] == 0x01);
  CtrlReassembler r;
  std::string msg, err;
  CHECK(r.Feed(chunks[0].data(), chunks[0].size(), &msg, &err));
  CHECK(msg == small);

  std::string big(kCtrlChunk * 3 + 17, 'x');
  chunks = SplitCtrlMessage(big);
  REQUIRE(chunks.size() == 4);
  CHECK(chunks[0][0] == 0x00);
  CHECK(chunks[3][0] == 0x01);
  CHECK(chunks[3].size() == 18);
  for (size_t i = 0; i < 3; ++i) CHECK_FALSE(r.Feed(chunks[i].data(), chunks[i].size(), &msg, &err));
  CHECK(r.Feed(chunks[3].data(), chunks[3].size(), &msg, &err));
  CHECK(msg == big);

  std::string empty;
  chunks = SplitCtrlMessage(empty);
  REQUIRE(chunks.size() == 1);
  CHECK(r.Feed(chunks[0].data(), chunks[0].size(), &msg, &err));
  CHECK(msg.empty());

  uint8_t bad[] = {0x05, 'a'};
  CHECK_FALSE(r.Feed(bad, 2, &msg, &err));
  CHECK_FALSE(err.empty());
  CHECK_FALSE(r.Feed(nullptr, 0, &msg, &err));

  nlohmann::json j;
  std::string type;
  CHECK(ParseCtrlMessage(R"({"type":"offer","x":1})", &j, &type));
  CHECK(type == "offer");
  CHECK(j["x"] == 1);
  CHECK_FALSE(ParseCtrlMessage("[1]", &j, &type));
  CHECK_FALSE(ParseCtrlMessage(R"({"type":5})", &j, &type));
  CHECK_FALSE(ParseCtrlMessage("{bad", &j, &type));
}

TEST_CASE("block math") {
  CHECK(BlockCountFor(0) == 0);
  CHECK(BlockCountFor(1) == 1);
  CHECK(BlockCountFor(kBlockPayloadSize) == 1);
  CHECK(BlockCountFor(kBlockPayloadSize + 1) == 2);
  CHECK(BlockLenFor(kBlockPayloadSize + 1, 0) == kBlockPayloadSize);
  CHECK(BlockLenFor(kBlockPayloadSize + 1, 1) == 1);
  CHECK(BlockLenFor(kBlockPayloadSize + 1, 2) == 0);
  CHECK(BlockLenFor(0, 0) == 0);
}

TEST_CASE("manifest build, serialize, validate") {
  const auto dir = std::filesystem::temp_directory_path() / "ct_manifest_test";
  std::filesystem::remove_all(dir);
  std::filesystem::create_directories(dir / "root" / "sub" / "empty");
  std::ofstream(dir / "root" / "a.txt") << "hello";
  std::ofstream(dir / "root" / "sub" / "b.bin") << std::string(3000, 'b');
  std::ofstream(dir / "single.dat") << "";
  std::ofstream(dir / "\xE4\xB8\xAD\xE6\x96\x87.txt") << "zh";

  Manifest m;
  std::vector<std::filesystem::path> abs;
  std::string err;
  REQUIRE(BuildManifest({(dir / "root").string(), (dir / "single.dat").string(),
                         (dir / "\xE4\xB8\xAD\xE6\x96\x87.txt").string()},
                        &m, &abs, &err));
  CHECK(m.roots.size() == 3);
  CHECK(m.files.size() == 4);
  CHECK(abs.size() == 4);
  CHECK(m.total_bytes == 5 + 3000 + 0 + 2);
  bool saw_empty_dir = false;
  for (const auto& d : m.dirs) saw_empty_dir |= d == "root/sub/empty";
  CHECK(saw_empty_dir);

  const auto j = m.ToJson();
  Manifest back;
  REQUIRE(Manifest::FromJson(j, &back, &err));
  CHECK(back.files.size() == 4);
  CHECK(back.total_bytes == m.total_bytes);
  CHECK(back.dirs == m.dirs);

  // Rejections.
  auto bad = j;
  bad["files"][0]["path"] = "../x";
  CHECK_FALSE(Manifest::FromJson(bad, &back, &err));
  bad = j;
  bad["files"][0]["path"] = "outside/x";
  CHECK_FALSE(Manifest::FromJson(bad, &back, &err));
  bad = j;
  bad["files"].push_back(bad["files"][0]);
  CHECK_FALSE(Manifest::FromJson(bad, &back, &err));
  bad = j;
  bad["files"][0]["size"] = -1;
  CHECK_FALSE(Manifest::FromJson(bad, &back, &err));
  bad = j;
  bad.erase("roots");
  CHECK_FALSE(Manifest::FromJson(bad, &back, &err));

  CHECK_FALSE(BuildManifest({(dir / "missing").string()}, &m, &abs, &err));
  CHECK_FALSE(BuildManifest({(dir / "root").string(), (dir / "root").string()}, &m, &abs, &err));
  CHECK_FALSE(BuildManifest({}, &m, &abs, &err));
  std::filesystem::remove_all(dir);
}
