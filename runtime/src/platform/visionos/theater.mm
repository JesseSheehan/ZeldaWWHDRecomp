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

#include "gfx/depth3d.h"
#include "motion/motion.h"
#include "guest_addr.h"
#include "imgui.h"
#include "overlay/extensions.h"
#include "overlay/hostui.h"
#include "overlay/widgets.h"
#include "runtime.h"

namespace gfx {
extern std::atomic<bool> g_metalfx;  // host.mm: MetalFX upscaling of the TV picture
extern std::atomic<int> g_metalfx_in_w, g_metalfx_in_h, g_metalfx_out_w, g_metalfx_out_h;  // its last frame
void save_graphics_options();
}  // namespace gfx

extern "C" double wwhd_visionos_gyro_last(float rate[3]);  // host.mm: the last controller gyro sample

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
static std::atomic<bool> g_game_memory{false};  // the game's memory is set up (theater_init ran)

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

// the Vision Pro tab (render thread, inside the overlay's frame): the picture, and Full Screen
static void draw_tab() {
    using namespace overlay::widgets;
    const bool active = g_active.load();
    auto act = [](int action, int value) {
        hostui::post([action, value] {
            if (auto fn = g_action.load()) fn(action, value);
        });
    };
    ImGui::SeparatorText("Picture");
    bool sharp = false;
    if (check("Sharper picture (MetalFX upscaling)", gfx::g_metalfx.load(), &sharp))
        hostui::post([sharp] {
            gfx::g_metalfx = sharp;
            gfx::save_graphics_options();
        });
    note("Enlarges the game picture to the window's (or Full Screen's) real pixels with Apple's MetalFX instead of "
         "plain filtering: crisper edges at the same internal resolution, for very little GPU time. Most visible at "
         "1x to 1.5x (Graphics > Internal resolution).");
    if (gfx::g_metalfx.load()) {
        if (const int ow = gfx::g_metalfx_out_w.load())
            note("Active: the game's %dx%d picture is upscaled to %dx%d.", gfx::g_metalfx_in_w.load(), gfx::g_metalfx_in_h.load(), ow,
                 gfx::g_metalfx_out_h.load());
        else
            note("Waiting: the picture is not enlarged right now (the window shows it at its size or smaller).");
    }
    ImGui::SeparatorText("Motion aiming");
    {
        motion::Settings g = motion::settings();
        bool gyro = false;
        if (check("Aim by moving the controller", g.source == motion::kController, &gyro)) {
            g.source = gyro ? motion::kController : motion::kOff;
            hostui::post([g] {
                motion::set_settings(g);
                for (const char* k : motion::kKeys) hostui::set(k, motion::value_of(g, k));
            });
        }
        float rate[3];
        const double age = wwhd_visionos_gyro_last(rate);
        if (g.source != motion::kController)
            note("Off (Settings > Controls > Gyro... has the other sources and the sensitivity).");
        else if (motion::gyro_controllers() == 0)
            note("No controller with motion sensors is connected (DualSense, DualShock 4, Switch Pro Controller).");
        else if (age < 0 || age > 1)
            note("%d controller(s) with motion sensors; no motion received yet.", motion::gyro_controllers());
        else
            note("Motion received: %.2f %.2f %.2f rad/s. Aim (bow, hookshot, telescope, first person) and move the "
                 "controller; keep the right stick still. The game's own Options > Gyro must be on.", rate[0], rate[1], rate[2]);
    }
    ImGui::SeparatorText("3D");
    bool on3d = false;
    if (check("3D", depth3d::enabled.load(), &on3d))
        hostui::post([on3d] {
            depth3d::enabled = on3d;
            gfx::save_graphics_options();
        });
    note("Each eye gets its own picture, made from the game's depth: the world gets depth, the HUD and menus "
         "stay at the screen. In the game window and in Full Screen. Off: no cost.");
    if (depth3d::enabled.load()) {
        float strength = depth3d::strength.load();
        if (ImGui::SliderFloat("Depth", &strength, 0.05f, 1.0f, "%.2f", ImGuiSliderFlags_AlwaysClamp)) {
            depth3d::strength = strength;
            hostui::post([] { gfx::save_graphics_options(); });
        }
        bool swapped = false;
        if (check("Swap eyes", depth3d::swap.load(), &swapped))
            hostui::post([swapped] {
                depth3d::swap = swapped;
                gfx::save_graphics_options();
            });
    }
    ImGui::SeparatorText("Full Screen");
    note("The game on a big screen in front of you: over the sea under a bright sky (the picture reflects in "
         "the water), in your dimmed room, or in your room as it is. The GamePad window stays where it is. "
         "Pinch the controls under the screen, or use this page.");
    ImGui::Spacing();
    if (ImGui::Button(active ? "Leave full screen" : "Full screen")) act(0, active ? 0 : 1);
    ImGui::SeparatorText("Screen");
    static const char* kSizes[] = {"Small (3 m wide, 4 m away)", "Medium (5 m wide, 7 m away)", "Huge (12 m wide, 12 m away)"};
    for (int i = 0; i < 3; i++)
        if (radio(kSizes[i], g_size.load() == i)) act(1, i);
    ImGui::SeparatorText("Surroundings");
    static const char* kEnvironments[] = {"The Great Sea (turn the Digital Crown to see your room)", "Your room, dimmed", "Your room"};
    for (int i = 0; i < 3; i++)
        if (radio(kEnvironments[i], g_environment.load() == i)) act(2, i);
}

// main thread, display_init (before the overlay's first frame)
void theater_init() {
    overlay::ext::Tab tab;
    tab.id = "visionpro";
    tab.name = "Vision Pro";
    tab.draw = draw_tab;
    overlay::ext::add_tab(std::move(tab), "audio");
    g_game_memory = true;
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

// The game's time of day in degrees (0..360, 15 per hour), or -1 before the game is up: dSv_info_c (the
// save base, d_com_inf_game) +0x44, as mods/story_notebook.cpp reads it. Full Screen's sky follows it.
extern "C" double wwhd_visionos_time_of_day() {
    if (!visionos::g_game_memory.load()) return -1;
    const uint32_t base = ld32(GD(0x101F84DC));
    if (!base) return -1;
    const float degrees = u32_as_f32(ld32(base + 0x44));
    return degrees >= 0 && degrees <= 360 ? degrees : -1;
}
