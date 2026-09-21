/*
 * CrossTransfer core — logging (spdlog).
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_LOG_LOG_H_
#define CT_LOG_LOG_H_

#include <memory>
#include <string>

// Compile every level in; the runtime level (config.log_level) filters.
#ifndef SPDLOG_ACTIVE_LEVEL
#define SPDLOG_ACTIVE_LEVEL SPDLOG_LEVEL_TRACE
#endif
#include "spdlog/spdlog.h"

namespace ct {

// Creates the "ct" logger (stdout + rotating file under log_dir). Safe to call
// more than once; later calls only adjust the level. `level` is one of
// trace|debug|info|warn|error|off.
void InitLog(const std::string& log_dir, const std::string& level);
void SetLogLevel(const std::string& level);
std::shared_ptr<spdlog::logger> Logger();

}  // namespace ct

#define CT_LOG_TRACE(...) SPDLOG_LOGGER_TRACE(::ct::Logger(), __VA_ARGS__)
#define CT_LOG_DEBUG(...) SPDLOG_LOGGER_DEBUG(::ct::Logger(), __VA_ARGS__)
#define CT_LOG_INFO(...) SPDLOG_LOGGER_INFO(::ct::Logger(), __VA_ARGS__)
#define CT_LOG_WARN(...) SPDLOG_LOGGER_WARN(::ct::Logger(), __VA_ARGS__)
#define CT_LOG_ERROR(...) SPDLOG_LOGGER_ERROR(::ct::Logger(), __VA_ARGS__)

#endif  // CT_LOG_LOG_H_
