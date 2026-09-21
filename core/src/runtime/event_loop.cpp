/*
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#include "runtime/event_loop.h"

#include <cassert>
#include <utility>

namespace ct {

EventLoop::EventLoop(std::string name) : name_(std::move(name)) {}

EventLoop::~EventLoop() { Stop(); }

void EventLoop::Start() {
  if (running_.exchange(true)) return;
  stop_ = false;
  thread_ = std::thread([this] { Run(); });
  thread_id_ = thread_.get_id();
}

void EventLoop::Stop() {
  if (!running_.load()) return;
  assert(!IsCurrent());
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stop_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) thread_.join();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.clear();
  }
  running_ = false;
}

void EventLoop::Post(Task task) { PostDelayed(std::move(task), 0); }

EventLoop::TimerId EventLoop::PostDelayed(Task task, int delay_ms) {
  const auto when = Clock::now() + std::chrono::milliseconds(delay_ms < 0 ? 0 : delay_ms);
  TimerId id;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    id = next_id_++;
    queue_.emplace(when, Entry{id, std::move(task)});
  }
  cv_.notify_one();
  return id;
}

void EventLoop::Cancel(TimerId id) {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto it = queue_.begin(); it != queue_.end(); ++it) {
    if (it->second.id == id) {
      queue_.erase(it);
      return;
    }
  }
}

bool EventLoop::IsCurrent() const {
  return running_.load() && std::this_thread::get_id() == thread_id_;
}

void EventLoop::RunSync(const Task& task) {
  assert(!IsCurrent());
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
  Post([&] {
    task();
    std::lock_guard<std::mutex> lock(m);
    done = true;
    cv.notify_one();
  });
  std::unique_lock<std::mutex> lock(m);
  cv.wait(lock, [&] { return done; });
}

void EventLoop::Run() {
  for (;;) {
    Task task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      for (;;) {
        if (stop_) return;
        if (queue_.empty()) {
          cv_.wait(lock);
          continue;
        }
        const auto now = Clock::now();
        auto first = queue_.begin();
        if (first->first <= now) {
          task = std::move(first->second.task);
          queue_.erase(first);
          break;
        }
        cv_.wait_until(lock, first->first);
      }
    }
    if (task) task();
  }
}

}  // namespace ct
