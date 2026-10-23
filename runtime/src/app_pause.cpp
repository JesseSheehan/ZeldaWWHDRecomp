// See app_pause.h.
#include "app_pause.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>

#include "audio_out.h"
#include "runtime.h"

namespace app_pause {
namespace {
std::mutex g_mu;
std::condition_variable g_cv;
bool g_requested = false;  // g_mu
std::atomic<bool> g_want{false}, g_paused{false};
}  // namespace

void request(bool on) {
    {
        std::lock_guard<std::mutex> lk(g_mu);
        g_requested = on;
    }
    g_want.store(on, std::memory_order_release);
    g_cv.notify_all();
}

bool paused() { return g_paused.load(std::memory_order_acquire); }

void service() {
    if (!g_want.load(std::memory_order_acquire)) return;
    const auto t0 = std::chrono::steady_clock::now();
    const uint64_t guest = timebase::guest_now();
    // the other guest threads park as for a save state; if one does not, this thread still stops (the
    // game's logic and drawing), and the rest wait on it soon enough
    std::string busy;
    const bool frozen = threads::quiesce(250, busy, 1, 30);
    if (!frozen) LOG("[pause] not every thread parked (%s); pausing the game thread only", busy.c_str());
    audio::set_paused(true);
    g_paused = true;
    LOG("[pause] game paused");
    {
        std::unique_lock<std::mutex> lk(g_mu);
        g_cv.wait(lk, [] { return !g_requested; });
    }
    g_paused = false;
    timebase::set_guest_now(guest);  // no time passed for the game
    threads::thaw();
    audio::set_paused(false);
    LOG("[pause] game resumed after %.1f s",
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
}

}  // namespace app_pause
