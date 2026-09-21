/*
 * CrossTransfer core — single-threaded event loop with delayed tasks.
 *
 * Copyright (c) 2026 DI JUNKUN. All Rights Reserved. Proprietary.
 */

#ifndef CT_RUNTIME_EVENT_LOOP_H_
#define CT_RUNTIME_EVENT_LOOP_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>

namespace ct {

class EventLoop {
 public:
  using Task = std::function<void()>;
  using TimerId = uint64_t;

  explicit EventLoop(std::string name = "ct-loop");
  ~EventLoop();
  EventLoop(const EventLoop&) = delete;
  EventLoop& operator=(const EventLoop&) = delete;

  void Start();
  // Stops the thread; queued tasks that have not run are discarded. May be
  // called from any thread except the loop thread itself.
  void Stop();

  void Post(Task task);
  // Runs task after delay_ms on the loop thread. Returns an id for Cancel.
  TimerId PostDelayed(Task task, int delay_ms);
  void Cancel(TimerId id);

  bool IsCurrent() const;
  bool Running() const { return running_.load(); }

  // Runs task on the loop and waits for completion (deadlocks if called on
  // the loop thread; asserts against it).
  void RunSync(const Task& task);

 private:
  struct Entry {
    TimerId id;
    Task task;
  };
  using Clock = std::chrono::steady_clock;

  void Run();

  std::string name_;
  std::thread thread_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stop_{false};
  std::mutex mutex_;
  std::condition_variable cv_;
  std::multimap<Clock::time_point, Entry> queue_;
  TimerId next_id_ = 1;
  std::thread::id thread_id_;
};

}  // namespace ct

#endif  // CT_RUNTIME_EVENT_LOOP_H_
