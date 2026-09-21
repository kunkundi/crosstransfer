/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "log/log.h"

#include <filesystem>
#include <mutex>
#include <system_error>
#include <vector>

#include "spdlog/sinks/rotating_file_sink.h"
#include "spdlog/sinks/stdout_color_sinks.h"

namespace ct {
namespace {

std::mutex g_mutex;
std::shared_ptr<spdlog::logger> g_logger;

spdlog::level::level_enum ParseLevel(const std::string& level) {
  if (level == "trace") return spdlog::level::trace;
  if (level == "debug") return spdlog::level::debug;
  if (level == "warn" || level == "warning") return spdlog::level::warn;
  if (level == "error") return spdlog::level::err;
  if (level == "off") return spdlog::level::off;
  return spdlog::level::info;
}

}  // namespace

void InitLog(const std::string& log_dir, const std::string& level) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_logger) {
    std::vector<spdlog::sink_ptr> sinks;
    sinks.push_back(std::make_shared<spdlog::sinks::stderr_color_sink_mt>());
    if (!log_dir.empty()) {
      std::error_code ec;
      std::filesystem::create_directories(log_dir, ec);
      try {
        sinks.push_back(std::make_shared<spdlog::sinks::rotating_file_sink_mt>(
            (std::filesystem::path(log_dir) / "crosstransfer.log").string(),
            5 * 1024 * 1024, 3));
      } catch (const spdlog::spdlog_ex&) {
        // Keep stderr only.
      }
    }
    g_logger = std::make_shared<spdlog::logger>("ct", sinks.begin(), sinks.end());
    g_logger->set_pattern("[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] [%t] %v");
    g_logger->flush_on(spdlog::level::warn);
    spdlog::register_logger(g_logger);
  }
  g_logger->set_level(ParseLevel(level));
}

void SetLogLevel(const std::string& level) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_logger) g_logger->set_level(ParseLevel(level));
}

std::shared_ptr<spdlog::logger> Logger() {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_logger) return g_logger;
  }
  InitLog("", "info");
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_logger;
}

}  // namespace ct
