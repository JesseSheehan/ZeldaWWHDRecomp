// visionOS host: theater mode. The app (WindWakerVisionApp.swift, TheaterSpace) shows the TV picture on a
// large screen in an immersive space; the screen's texture is a RealityKit DrawableQueue, which the app
// hands over as two calls: `next` gives the queue's next texture (render thread; NULL: none free yet) and
// `present` presents it when the command buffer that drew into it completes. host.mm's present_screens
// composes the TV picture (with the GamePad picture-in-picture and the settings overlay) into that texture
// instead of the TV window's layer while they are set: no copy, the same pass.
//
// The settings menu gets a Theater tab, so a controller alone can enter and leave theater mode and pick the
// screen and the surroundings; its choices go to the app (wwhd_visionos_set_theater_actions), which owns the
// immersive space and reports back what is showing (wwhd_visionos_theater_state).
#import <Metal/Metal.h>

#include <atomic>
#include <functional>
#include <mutex>

#include "imgui.h"
#include "overlay/extensions.h"
#include "overlay/hostui.h"
#include "overlay/widgets.h"
#include "runtime.h"

typedef void* (*wwhd_theater_next_fn)(void);
typedef void (*wwhd_theater_present_fn)(void* command_buffer);
typedef void (*wwhd_theater_action_fn)(int action, int value);

namespace visionos {

static std::mutex g_mu;  // held while a frame is drawn into the theater texture
static wwhd_theater_next_fn g_next;
static wwhd_theater_present_fn g_present;
static int g_width, g_height;  // the theater texture's size
static std::atomic<wwhd_theater_action_fn> g_action{nullptr};
static std::atomic<int> g_active{0}, g_size{1}, g_environment{0};

// any thread: theater mode is on, and the size of its texture
bool theater_size(int& w, int& h) {
    std::lock_guard<std::mutex> lk(g_mu);
    w = g_width;
    h = g_height;
    return g_next != nullptr;
}

// render thread (present_screens): draws into the theater's next texture; false when theater mode is off
// (or no texture is free: that frame is not shown there)
bool theater_frame(const std::function<void(id<MTLTexture>)>& compose, id<MTLCommandBuffer> cb) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (!g_next) return false;
    void* t = g_next();
    if (!t) return false;
    compose((__bridge id<MTLTexture>)t);
    g_present((__bridge void*)cb);
    return true;
}

// the Theater tab (render thread, inside the overlay's frame)
static void draw_tab() {
    using namespace overlay::widgets;
    const bool active = g_active.load();
    auto act = [](int action, int value) {
        hostui::post([action, value] {
            if (auto fn = g_action.load()) fn(action, value);
        });
    };
    note("The game on a big screen in front of you, in a sky over the sea or in your dimmed room. The "
         "GamePad window stays where it is. Pinch the controls under the screen, or use this page.");
    ImGui::Spacing();
    if (ImGui::Button(active ? "Leave theater mode" : "Enter theater mode")) act(0, active ? 0 : 1);
    ImGui::SeparatorText("Screen");
    static const char* kSizes[] = {"Small (3 m wide, 4 m away)", "Medium (5 m wide, 7 m away)", "Huge (12 m wide, 12 m away)"};
    for (int i = 0; i < 3; i++)
        if (radio(kSizes[i], g_size.load() == i)) act(1, i);
    ImGui::SeparatorText("Surroundings");
    static const char* kEnvironments[] = {"Sky and sea (turn the Digital Crown to see your room)", "Your room, dimmed"};
    for (int i = 0; i < 2; i++)
        if (radio(kEnvironments[i], g_environment.load() == i)) act(2, i);
}

// main thread, display_init (before the overlay's first frame)
void theater_init() {
    overlay::ext::Tab tab;
    tab.id = "theater";
    tab.name = "Theater";
    tab.draw = draw_tab;
    overlay::ext::add_tab(std::move(tab), "audio");
}

}  // namespace visionos

// ---------------------------------------------------------------- the app's calls
extern "C" void wwhd_visionos_set_theater(wwhd_theater_next_fn next, wwhd_theater_present_fn present, int width, int height) {
    const bool on = next && present && width > 0 && height > 0;
    {
        std::lock_guard<std::mutex> lk(visionos::g_mu);
        visionos::g_next = on ? next : nullptr;
        visionos::g_present = on ? present : nullptr;
        visionos::g_width = width;
        visionos::g_height = height;
    }
    if (on) LOG("[visionos] theater screen on (%dx%d)", width, height);
    else LOG("[visionos] theater screen off");
}

extern "C" void wwhd_visionos_set_theater_actions(wwhd_theater_action_fn fn) { visionos::g_action = fn; }

extern "C" void wwhd_visionos_theater_state(int active, int size, int environment) {
    visionos::g_active = active;
    visionos::g_size = size;
    visionos::g_environment = environment;
}
