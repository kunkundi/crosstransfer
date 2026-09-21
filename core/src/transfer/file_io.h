/*
 * CrossTransfer core — positional file I/O and filesystem helpers.
 *
 * One reader/writer object is used from a single I/O thread at a time.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_TRANSFER_FILE_IO_H_
#define CT_TRANSFER_FILE_IO_H_

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>

namespace ct {

class FileReader {
 public:
  FileReader() = default;
  ~FileReader();
  FileReader(const FileReader&) = delete;
  FileReader& operator=(const FileReader&) = delete;

  bool Open(const std::filesystem::path& path, std::string* err = nullptr);
  bool IsOpen() const { return fp_ != nullptr; }
  uint64_t Size() const { return size_; }
  // Reads up to len bytes at offset; *got < len only at EOF. False on error.
  bool ReadAt(uint64_t offset, void* buf, size_t len, size_t* got);
  void Close();

 private:
  std::FILE* fp_ = nullptr;
  uint64_t size_ = 0;
  uint64_t pos_ = 0;
};

class FileWriter {
 public:
  FileWriter() = default;
  ~FileWriter();
  FileWriter(const FileWriter&) = delete;
  FileWriter& operator=(const FileWriter&) = delete;

  // Opens (creates if missing, never truncates) for read/write. Parent
  // directories must exist.
  bool Open(const std::filesystem::path& path, std::string* err = nullptr);
  bool IsOpen() const { return fp_ != nullptr; }
  bool WriteAt(uint64_t offset, const void* buf, size_t len);
  // Extends the file to `size` bytes if it is shorter (sparse where possible).
  bool EnsureSize(uint64_t size);
  bool Flush();
  void Close();

 private:
  std::FILE* fp_ = nullptr;
  uint64_t pos_ = 0;
};

// mkdir -p. True if the directory exists afterwards.
bool EnsureDir(const std::filesystem::path& dir, std::string* err = nullptr);
// Atomic-ish rename that replaces an existing destination file.
bool RenameReplace(const std::filesystem::path& from,
                   const std::filesystem::path& to, std::string* err = nullptr);
// Writes data to path via a temporary sibling + rename.
bool WriteFileAtomic(const std::filesystem::path& path, const std::string& data,
                     std::string* err = nullptr);
bool ReadFileToString(const std::filesystem::path& path, std::string* out,
                      std::string* err = nullptr);
// Creates an empty regular file (truncating). True on success.
bool CreateEmptyFile(const std::filesystem::path& path, std::string* err = nullptr);
// Free bytes on the volume holding path (0 if unknown).
uint64_t FreeSpace(const std::filesystem::path& path);

}  // namespace ct

#endif  // CT_TRANSFER_FILE_IO_H_
