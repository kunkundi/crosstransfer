/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "transfer/file_io.h"

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <system_error>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#define fseeko _fseeki64
#define ftello _ftelli64
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace ct {
namespace {

std::string ErrnoString() { return std::strerror(errno); }

std::FILE* OpenFile(const std::filesystem::path& path, const char* mode) {
#ifdef _WIN32
  std::wstring wmode(mode, mode + std::strlen(mode));
  return _wfopen(path.c_str(), wmode.c_str());
#else
  return std::fopen(path.c_str(), mode);
#endif
}

bool SizeOf(std::FILE* fp, uint64_t* size) {
  if (fseeko(fp, 0, SEEK_END) != 0) return false;
  const auto end = ftello(fp);
  if (end < 0) return false;
  *size = static_cast<uint64_t>(end);
  return true;
}

}  // namespace

// ---- FileReader --------------------------------------------------------------

FileReader::~FileReader() { Close(); }

bool FileReader::Open(const std::filesystem::path& path, std::string* err) {
  Close();
  fp_ = OpenFile(path, "rb");
  if (!fp_) {
    if (err) *err = ErrnoString();
    return false;
  }
  if (!SizeOf(fp_, &size_)) {
    if (err) *err = ErrnoString();
    Close();
    return false;
  }
  pos_ = size_;
  return true;
}

bool FileReader::ReadAt(uint64_t offset, void* buf, size_t len, size_t* got) {
  if (!fp_ || !buf || !got) return false;
  *got = 0;
  if (len == 0) return true;
#ifndef _WIN32
  const int fd = fileno(fp_);
  size_t total = 0;
  while (total < len) {
    const ssize_t n = pread(fd, static_cast<char*>(buf) + total, len - total,
                            static_cast<off_t>(offset + total));
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) break;
    total += static_cast<size_t>(n);
  }
  *got = total;
  return true;
#else
  if (pos_ != offset) {
    if (fseeko(fp_, static_cast<int64_t>(offset), SEEK_SET) != 0) return false;
    pos_ = offset;
  }
  const size_t n = std::fread(buf, 1, len, fp_);
  pos_ += n;
  *got = n;
  return n == len || std::ferror(fp_) == 0;
#endif
}

void FileReader::Close() {
  if (fp_) std::fclose(fp_);
  fp_ = nullptr;
  size_ = 0;
  pos_ = 0;
}

// ---- FileWriter --------------------------------------------------------------

FileWriter::~FileWriter() { Close(); }

bool FileWriter::Open(const std::filesystem::path& path, std::string* err) {
  Close();
#ifdef _WIN32
  fp_ = OpenFile(path, "r+b");
  if (!fp_) fp_ = OpenFile(path, "w+b");
  if (!fp_) {
    if (err) *err = ErrnoString();
    return false;
  }
#else
  int fd;
  do {
    fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0644);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    if (err) *err = ErrnoString();
    return false;
  }
  fp_ = fdopen(fd, "r+b");
  if (!fp_) {
    if (err) *err = ErrnoString();
    ::close(fd);
    return false;
  }
#endif
  pos_ = 0;
  return true;
}

bool FileWriter::WriteAt(uint64_t offset, const void* buf, size_t len) {
  if (!fp_) return false;
  if (len == 0) return true;
#ifndef _WIN32
  const int fd = fileno(fp_);
  size_t total = 0;
  while (total < len) {
    const ssize_t n = pwrite(fd, static_cast<const char*>(buf) + total, len - total,
                             static_cast<off_t>(offset + total));
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    total += static_cast<size_t>(n);
  }
  return true;
#else
  if (pos_ != offset) {
    if (fseeko(fp_, static_cast<int64_t>(offset), SEEK_SET) != 0) return false;
    pos_ = offset;
  }
  const size_t n = std::fwrite(buf, 1, len, fp_);
  pos_ += n;
  return n == len;
#endif
}

bool FileWriter::EnsureSize(uint64_t size) {
  if (!fp_) return false;
  uint64_t cur = 0;
#ifndef _WIN32
  struct stat st;
  if (fstat(fileno(fp_), &st) != 0) return false;
  cur = static_cast<uint64_t>(st.st_size);
  if (cur >= size) return true;
  return ftruncate(fileno(fp_), static_cast<off_t>(size)) == 0;
#else
  std::fflush(fp_);
  if (!SizeOf(fp_, &cur)) return false;
  pos_ = cur;
  if (cur >= size) return true;
  return _chsize_s(_fileno(fp_), static_cast<int64_t>(size)) == 0;
#endif
}

bool FileWriter::Flush() {
  if (!fp_) return false;
  return std::fflush(fp_) == 0;
}

void FileWriter::Close() {
  if (fp_) std::fclose(fp_);
  fp_ = nullptr;
  pos_ = 0;
}

// ---- helpers -----------------------------------------------------------------

bool EnsureDir(const std::filesystem::path& dir, std::string* err) {
  std::error_code ec;
  if (std::filesystem::is_directory(dir, ec)) return true;
  std::filesystem::create_directories(dir, ec);
  if (ec) {
    if (err) *err = ec.message();
    return false;
  }
  return std::filesystem::is_directory(dir, ec);
}

bool RenameReplace(const std::filesystem::path& from, const std::filesystem::path& to,
                   std::string* err) {
#ifdef _WIN32
  if (!MoveFileExW(from.c_str(), to.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED)) {
    if (err) *err = "MoveFileExW failed: " + std::to_string(GetLastError());
    return false;
  }
  return true;
#else
  std::error_code ec;
  std::filesystem::rename(from, to, ec);
  if (ec) {
    if (err) *err = ec.message();
    return false;
  }
  return true;
#endif
}

bool WriteFileAtomic(const std::filesystem::path& path, const std::string& data,
                     std::string* err) {
  std::filesystem::path tmp = path;
  tmp += ".tmp";
  std::FILE* fp = OpenFile(tmp, "wb");
  if (!fp) {
    if (err) *err = ErrnoString();
    return false;
  }
  const bool ok = data.empty() || std::fwrite(data.data(), 1, data.size(), fp) == data.size();
  const bool flushed = std::fflush(fp) == 0;
  std::fclose(fp);
  if (!ok || !flushed) {
    if (err) *err = ErrnoString();
    std::error_code ec;
    std::filesystem::remove(tmp, ec);
    return false;
  }
  return RenameReplace(tmp, path, err);
}

bool ReadFileToString(const std::filesystem::path& path, std::string* out, std::string* err) {
  if (!out) return false;
  std::FILE* fp = OpenFile(path, "rb");
  if (!fp) {
    if (err) *err = ErrnoString();
    return false;
  }
  out->clear();
  char buf[65536];
  for (;;) {
    const size_t n = std::fread(buf, 1, sizeof(buf), fp);
    if (n > 0) out->append(buf, n);
    if (n < sizeof(buf)) break;
  }
  const bool ok = std::ferror(fp) == 0;
  std::fclose(fp);
  if (!ok && err) *err = "read error";
  return ok;
}

bool CreateEmptyFile(const std::filesystem::path& path, std::string* err) {
  std::FILE* fp = OpenFile(path, "wb");
  if (!fp) {
    if (err) *err = ErrnoString();
    return false;
  }
  std::fclose(fp);
  return true;
}

uint64_t FreeSpace(const std::filesystem::path& path) {
  std::error_code ec;
  const auto info = std::filesystem::space(path, ec);
  if (ec) return 0;
  return static_cast<uint64_t>(info.available);
}

}  // namespace ct
