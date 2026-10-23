// visionOS host (Apple Vision Pro): what the AppKit host (gfx/display.mm, input.mm, menu.mm,
// overlay_appkit.mm, mods/mouse.mm) does on macOS, for the visionOS app (visionos/WindWakerVision).
//
// The app owns main() and the main thread's run loop. It calls, on the main thread:
//   wwhd_visionos_reserve_memory()  first thing at launch: the guest address space (mem::reserve)
//   wwhd_visionos_set_layer(layer)  the CAMetalLayer of its view, which the TV picture is presented to
//   wwhd_runtime_main(argc, argv)   main.cpp's start-up; returns once the game threads run
//   wwhd_visionos_set_drawable_size(w, h, scale) whenever the view's size changes
//   wwhd_visionos_set_layer(layer or NULL) later: the TV window closed (NULL) or opened again (its new layer);
//                                   while it is closed the game runs on (the GamePad window shows it)
// and for the GamePad window (any time; it may open before or after the runtime starts, and close):
//   wwhd_visionos_set_drc_layer(layer or NULL), wwhd_visionos_set_drc_drawable_size(w, h, scale),
//   wwhd_visionos_drc_touch(down, x, y, w, h)  a pinch / touch on it (view points)
//   wwhd_visionos_toggle_settings()            the settings overlay (in the TV window) open / closed
//
// Two windows: the TV picture (with the settings overlay) and the GamePad screen. The GamePad screen
// modes are the desktop's (display_modes.h); in window mode a closed GamePad window falls back to the
// picture-in-picture. Game controllers through GameController.framework, settings in NSUserDefaults,
// typed text with the system keyboard (text_input.mm). While the app is not in front (headset off, Home,
// another app) the game is paused, after a "Last session" state (app_pause.h, below). No mouse or file
// panels yet.
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>

#include <algorithm>
#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <tuple>

#include "gfx/display.h"
#include "gfx/display_modes.h"
#include "gfx/metal.h"
#include "gfx/renderer.h"
#include "gfx/warm_progress.h"
#include "gx2/gx2.h"
#include "guest_addr.h"
#include "input.h"
#include "input_map.h"
#include "interp.h"
#include "imgui.h"
#include "backends/imgui_impl_metal.h"
#include "mods/mods.h"
#include "overlay/guest_hud.h"
#include "overlay/hostui.h"
#include "overlay/overlay.h"
#include "overlay/release_gate.h"
#include "runtime.h"
#include "app_pause.h"
#include "savestate.h"

namespace visionos {
void text_input_init(UIView* view);  // text_input.mm
void text_input_poll();
}  // namespace visionos

namespace gfx {
extern Renderer R;
void save_display_options();
void save_graphics_options();
}  // namespace gfx

// ---------------------------------------------------------------- the app's calls
static std::mutex g_tv_mu;
static CAMetalLayer* g_layer;   // the TV window's layer (g_tv_mu); nil while that window is closed
static bool g_display_ready;    // display_init ran (main thread)
static std::atomic<bool> g_tv_open{false};
static std::mutex g_drc_mu;
static CAMetalLayer* g_drc_layer;  // the GamePad window's layer; nil while that window is closed

extern "C" int wwhd_visionos_reserve_memory() {
    const int kr = mem::reserve();
    if (kr == KERN_SUCCESS) return kr;
    // what holds the address (the region at or after the guest base), for the log
    vm_address_t a = (vm_address_t)PPC_MEM_BASE;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const kern_return_t rr =
        vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    fprintf(stderr, "[visionos] cannot reserve the guest address space at %p (kr=%d %s); region there: kr=%d %llx-%llx prot %d/%d\n",
            PPC_MEM_BASE, kr, mach_error_string(kr), rr, (unsigned long long)a, (unsigned long long)(a + size), info.protection,
            info.max_protection);
    return kr;
}

namespace visionos {
void text_input_attach(UIView* view);  // text_input.mm
}
static void configure_tv_layer(CAMetalLayer* l);

extern "C" void wwhd_visionos_set_layer(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (l && g_display_ready) configure_tv_layer(l);
    {
        std::lock_guard<std::mutex> lk(g_tv_mu);
        g_layer = l;
        if (g_display_ready) gfx::R.tv.layer = l;
    }
    g_tv_open = l != nil;
    if (g_display_ready) {
        if (UIView* view = [l.delegate isKindOfClass:[UIView class]] ? (UIView*)l.delegate : nil) visionos::text_input_attach(view);
        LOG("[visionos] TV window %s", l ? "open" : "closed");
    }
}

extern "C" void wwhd_visionos_set_drawable_size(double w, double h, double scale) {
    std::lock_guard<std::mutex> lk(g_tv_mu);
    if (!g_layer) return;
    g_layer.contentsScale = scale;
    g_layer.drawableSize = CGSizeMake(std::max(1.0, w * scale), std::max(1.0, h * scale));
    overlay::set_density((float)scale);
}

namespace gfx {
// the picture's size at the full internal resolution (dynamic resolution renders it smaller; the layout stays)
static float nominal_w(const Screen& s) { return s.tex ? float(s.tex.width) / s.dyn : 0.0f; }
static float nominal_h(const Screen& s) { return s.tex ? float(s.tex.height) / s.dyn : 0.0f; }

// ---------------------------------------------------------------- settings (NSUserDefaults, "wwhd." keys)
bool host_setting(const char* key, std::string& value) {
    NSString* v = [[NSUserDefaults standardUserDefaults] stringForKey:[@"wwhd." stringByAppendingString:@(key)]];
    if (!v) return false;
    value = v.UTF8String;
    return true;
}
void set_host_setting(const char* key, const std::string& value) {
    [[NSUserDefaults standardUserDefaults] setObject:@(value.c_str()) forKey:[@"wwhd." stringByAppendingString:@(key)]];
}

void show_startup_notice(const std::string& title, const std::string& text) {
    LOG("[display] %s: %s", title.c_str(), text.c_str());
}

// the app's run loop is UIKit's: nothing to run here (main.cpp returns to the app)
void run_appkit_loop() {}

// ---------------------------------------------------------------- presentation (as display.mm)
static const char* kPresentShader = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut present_vs(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.uv = p * 0.5;
    float2 ndc = rect.xy + p * 0.5 * rect.zw;
    o.pos = float4(ndc.x * 2.0 - 1.0, 1.0 - ndc.y * 2.0, 0.0, 1.0);
    return o;
}
struct Params { int conv; float sharp; float foot; };
static float3 to_linear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
static float3 to_srgb(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
fragment float4 present_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                           constant Params& p [[buffer(0)]]) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 uv = in.uv;
    if (p.sharp > 1.0) {
        float2 t = uv * size - 0.5, i = floor(t), f = t - i;
        f = clamp((f - 0.5) * p.sharp + 0.5, 0.0, 1.0);
        uv = (i + f + 0.5) / size;
    }
    float3 c;
    if (p.foot > 1.25) {
        float2 d = 0.25 * min(p.foot, 4.0) / size;
        c = 0.25 * (tex.sample(s, uv + float2(-d.x, -d.y)).rgb + tex.sample(s, uv + float2(d.x, -d.y)).rgb +
                    tex.sample(s, uv + float2(-d.x, d.y)).rgb + tex.sample(s, uv + float2(d.x, d.y)).rgb);
    } else {
        c = tex.sample(s, uv).rgb;
    }
    if (p.conv == 1) c = to_linear(saturate(c));
    else if (p.conv == 2) c = to_srgb(saturate(c));
    return float4(c, 1.0);
}
fragment float4 solid_fs(VOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }
)";

static id<MTLLibrary> g_lib;
static id<MTLRenderPipelineState> pipeline(MTLPixelFormat fmt, bool solid, bool blend) {
    static std::mutex mu;
    static std::map<std::tuple<int, bool, bool>, id<MTLRenderPipelineState>> cache;
    std::lock_guard<std::mutex> lk(mu);
    auto key = std::make_tuple((int)fmt, solid, blend);
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_lib newFunctionWithName:@"present_vs"];
    d.fragmentFunction = [g_lib newFunctionWithName:solid ? @"solid_fs" : @"present_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    if (blend) {
        auto* a = d.colorAttachments[0];
        a.blendingEnabled = YES;
        a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = solid ? MTLBlendFactorSourceAlpha : MTLBlendFactorBlendAlpha;
        a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor =
            solid ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusBlendAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> p = [R.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) fatal("present pipeline: %s", err.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static bool is_srgb(MTLPixelFormat f) { return f == MTLPixelFormatBGRA8Unorm_sRGB || f == MTLPixelFormatRGBA8Unorm_sRGB; }

static void draw_image(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, id<MTLTexture> tex,
                       bool src_linear, Box b, float alpha, float dyn) {
    if (!tex || b.w <= 0 || b.h <= 0) return;
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    bool blend = alpha < 0.999f;
    [e setRenderPipelineState:pipeline(fmt, false, blend)];
    if (blend) [e setBlendColorRed:0 green:0 blue:0 alpha:alpha];
    struct { int conv; float sharp, foot; } p;
    bool dst_linear = is_srgb(fmt);
    p.conv = src_linear == dst_linear ? 0 : dst_linear ? 1 : 2;
    float scale = std::min(b.w / tex.width, b.h / tex.height);
    int filter = g_filter;
    float sharpScale = scale;
    if (dyn < 1.0f) {
        if (filter == kInteger) filter = kSmooth;
        else if (filter == kSharp) sharpScale = std::min(b.w / (tex.width / dyn), b.h / (tex.height / dyn));
    }
    p.sharp = filter == kSmooth || sharpScale <= 1.0f ? 1.0f : filter == kSharp ? sharpScale : 1e4f;
    p.foot = scale < 1.0f ? 1.0f / scale : 1.0f;
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentTexture:tex atIndex:0];
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e setFragmentSamplerState:R.linearClamp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void draw_solid(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, Box b, const float rgba[4]) {
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    [e setRenderPipelineState:pipeline(fmt, true, true)];
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentBytes:rgba length:16 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static ImDrawData* g_overlay_draw = nullptr;
static void overlay_metal_init() { ImGui_ImplMetal_Init(R.device); }

// the window's picture: TV image scaled to fit, GamePad picture-in-picture, settings overlay on top
static void compose_tv(id<MTLTexture> target, const Layout& L) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    float dw = target.width, dh = target.height;
    MTLPixelFormat fmt = target.pixelFormat;
    draw_image(e, fmt, dw, dh, R.tv.tex, R.tv.srgb, L.tv, 1.0f, R.tv.dyn);
    if (L.pip_on && R.drc.tex) {
        float op = L.drc_only ? 1.0f : g_pip_opacity.load(), bw = std::max(1.0f, roundf(L.pip.w / 200.0f));
        float frame[4] = {0, 0, 0, 0.6f * op};
        draw_solid(e, fmt, dw, dh, {L.pip.x - bw, L.pip.y - bw, L.pip.w + 2 * bw, L.pip.h + 2 * bw}, frame);
        draw_image(e, fmt, dw, dh, R.drc.tex, R.drc.srgb, L.pip, op, R.drc.dyn);
        if (auto* draw = overlay::guesthud::gamepad_region(dw, dh, L.pip.x, L.pip.y, L.pip.w, L.pip.h, op)) {
            if (is_srgb(fmt)) overlay::linearize_colors(draw, true);
            ImGui_ImplMetal_NewFrame(rp);
            ImGui_ImplMetal_RenderDrawData(draw, command_buffer(), e);
        }
    }
    if (g_overlay_draw) {
        if (is_srgb(fmt)) overlay::linearize_colors(g_overlay_draw);
        ImGui_ImplMetal_NewFrame(rp);
        ImGui_ImplMetal_RenderDrawData(g_overlay_draw, command_buffer(), e);
    }
    [e endEncoding];
}

// the GamePad window's picture: the GamePad image fitted, with the game's GamePad HUD markers
static void compose_drc(id<MTLTexture> target) {
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    Layout L = layout(target.width, target.height, nominal_w(R.drc), nominal_h(R.drc), 0, 0, false);
    draw_image(e, target.pixelFormat, target.width, target.height, R.drc.tex, R.drc.srgb, L.tv, 1.0f, R.drc.dyn);
    if (auto* draw = overlay::guesthud::gamepad_region(target.width, target.height, L.tv.x, L.tv.y, L.tv.w, L.tv.h, 1)) {
        if (is_srgb(target.pixelFormat)) overlay::linearize_colors(draw, true);
        ImGui_ImplMetal_NewFrame(rp);
        ImGui_ImplMetal_RenderDrawData(draw, command_buffer(), e);
    }
    [e endEncoding];
}

// ---------------------------------------------------------------- saved options (as menu.mm and display.mm)
static bool saved_float(const char* key, float& v) {
    std::string s;
    if (!host_setting(key, s) || s.empty()) return false;
    v = strtof(s.c_str(), nullptr);
    return true;
}
static void set_float(const char* key, double v) {
    char b[32];
    snprintf(b, sizeof b, "%g", v);
    set_host_setting(key, b);
}
void save_display_options() {
    set_host_setting("drcMode", kModeNames[display_saved_mode()]);
    set_host_setting("pipAnchor", kAnchorNames[g_pip_anchor]);
    set_float("pipSize", g_pip_size);
    set_float("pipOpacity", g_pip_opacity);
    set_host_setting("scaleFilter", kFilterNames[g_filter]);
}
static void load_display_options() {
    std::string s;
    g_mode = find_name(kModeNames, kDrcModeCount, host_setting("drcMode", s) ? s.c_str() : nullptr, kDrcWindow);
    g_pip_anchor = pip_load_anchor(host_setting("pipAnchor", s) ? s.c_str() : nullptr, nullptr);
    float v;
    if (saved_float("pipSize", v)) g_pip_size = pip_clamp_size(v);
    if (saved_float("pipOpacity", v)) g_pip_opacity = pip_clamp_opacity(v);
    g_filter = find_name(kFilterNames, 3, host_setting("scaleFilter", s) ? s.c_str() : nullptr, kSmooth);
    g_shown = true;
    display_env_overrides();  // start-up overrides for tests (not saved)
}
// the Graphics options (menu.mm's prefs: the same keys)
void save_graphics_options() {
    set_float("resScale", render::res_scale());
    set_float("aoMode", render::ao_mode());
    set_float("aoHires", render::ao_hires());
    set_float("aniso", render::aniso());
    set_float("fxaa", render::fxaa());
    set_float("bloomStrength", render::bloom_strength());
    set_float("fps60", interp::mode());
    set_float("interpFps", interp::fps());
    set_float("fps60Paced", interp::paced_interpolation_at(60));
}
static void load_graphics_options() {
    float v;
    if (saved_float("resScale", v) && !getenv("WWHD_RES_SCALE")) render::set_res_scale(v);
    if (saved_float("aoMode", v)) render::set_ao_mode((int)v);
    if (saved_float("aoHires", v)) render::set_ao_hires(v != 0);
    if (saved_float("aniso", v)) render::set_aniso(v != 0);
    if (saved_float("fxaa", v)) render::set_fxaa(v != 0);
    if (saved_float("bloomStrength", v)) render::set_bloom_strength(v);
    if (saved_float("interpFps", v) && !getenv("WWHD_INTERP_FPS")) interp::set_fps((int)v);
    if (saved_float("fps60", v) && !getenv("WWHD_INTERP") && !getenv("WWHD_TRUE60")) interp::set_mode((int)v);
    if (saved_float("fps60Paced", v)) interp::load_paced_interpolation_at(60, v != 0);
}

// ---------------------------------------------------------------- pause and resume (app_pause.h)
// Not in front: write the "Last session" state (savestate.h, slot 110: Link's place and progress; the
// game's own saves are untouched) while the game still runs, then pause it. "resumePending" tells the
// app's next start that this state is newer than what the player last saw, if the system ends the app
// in the background meanwhile; coming back clears it.
static void app_inactive() {
    if (app_pause::paused()) return;
    const bool saved = ss::save_last_session(1000);
    set_host_setting("resumePending", saved ? "1" : "0");
    [[NSUserDefaults standardUserDefaults] synchronize];
    app_pause::request(true);
    LOG("[visionos] app inactive: pausing the game (last session state %s)", saved ? "written" : "not written");
}
static void app_active() {
    set_host_setting("resumePending", "0");
    app_pause::request(false);
}
static void lifecycle_init() {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) { app_inactive(); }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) { app_active(); }];
}

} // namespace gfx
static void configure_tv_layer(CAMetalLayer* l) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    l.colorspace = cs;
    CGColorSpaceRelease(cs);
    l.device = gfx::R.device;
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.framebufferOnly = YES;
    l.maximumDrawableCount = 3;
}
namespace gfx {

// Metal renderer start-up (metal_main.mm): the app's layer, input, the presentation pipelines
void display_init() {
    if (!g_layer) fatal("visionOS: no layer (wwhd_visionos_set_layer before wwhd_runtime_main)");
    load_display_options();
    configure_tv_layer(g_layer);
    R.tv.layer = g_layer;
    g_tv_open = true;
    R.drc.layer = nil;
    R.drc.visible = false;
    interp::set_display_hz(90);
    input::init();
    NSError* err = nil;
    g_lib = [R.device newLibraryWithSource:@(kPresentShader) options:nil error:&err];
    if (!g_lib) fatal("present shader: %s", err.localizedDescription.UTF8String);
    R.presentPipeline = pipeline(MTLPixelFormatBGRA8Unorm, false, false);
    R.presentPipelineSRGB = pipeline(MTLPixelFormatBGRA8Unorm_sRGB, false, false);
    load_graphics_options();
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    R.linearClamp = [R.device newSamplerStateWithDescriptor:sd];
    if (UIView* view = [g_layer.delegate isKindOfClass:[UIView class]] ? (UIView*)g_layer.delegate : nil)
        visionos::text_input_init(view);
    lifecycle_init();
    g_display_ready = true;
    LOG("[visionos] display ready (%.0fx%.0f)", g_layer.drawableSize.width, g_layer.drawableSize.height);
}

// Metal, called from swap() on the render thread: compose and present the window
void present_screens() {
    Screen& scr = R.tv;
    CAMetalLayer* tv;
    {
        std::lock_guard<std::mutex> lk(g_tv_mu);
        tv = scr.layer;
    }
    // while the TV window is closed the overlay keeps the size it last had (it still runs: text prompt)
    static CGSize last_size = CGSizeMake(1920, 1080);
    if (tv) last_size = tv.drawableSize;
    CGSize ls = last_size;
    PresentPlan P = display_plan(R.tv.tex != nil, nominal_w(R.tv), nominal_h(R.tv), R.drc.tex != nil, nominal_w(R.drc),
                                 nominal_h(R.drc), ls.width, ls.height, R.frame);
    Layout L;
    L.tv = P.tv;
    L.pip = P.pip;
    L.pip_on = P.pip_on;
    L.drc_only = P.drc_only;
    L.scale = P.scale;
    if (overlay::guesthud::active()) overlay::guesthud::set_tv_region(P.tv.x, P.tv.y, P.tv.w, P.tv.h, !P.drc_only);
    g_overlay_draw = overlay::frame(P.dw, P.dh, overlay_metal_init);
    if (tv && scr.tex) {
        MTLPixelFormat want = scr.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
        if (tv.pixelFormat != want) tv.pixelFormat = want;
        if (id<CAMetalDrawable> drawable = scr.visible ? [tv nextDrawable] : nil) {
            static bool first = true;
            if (first) {
                first = false;
                LOG("[visionos] first frame presented (frame %llu, picture %.0fx%.0f, drawable %.0fx%.0f)", (unsigned long long)R.frame,
                    nominal_w(R.tv), nominal_h(R.tv), ls.width, ls.height);
            }
            compose_tv(drawable.texture, L);
            [command_buffer() presentDrawable:drawable];
        }
    }
    // the GamePad window (window mode)
    CAMetalLayer* drc;
    {
        std::lock_guard<std::mutex> lk(g_drc_mu);
        drc = g_drc_layer;
    }
    if (P.drc_window && drc && R.drc.tex) {
        if (!drc.device) drc.device = R.device;
        MTLPixelFormat want = R.drc.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
        if (drc.pixelFormat != want) drc.pixelFormat = want;
        if (id<CAMetalDrawable> drawable = [drc nextDrawable]) {
            compose_drc(drawable.texture);
            [command_buffer() presentDrawable:drawable];
        }
    }
}

}  // namespace gfx

// ---------------------------------------------------------------- settings overlay host (overlay/hostui.h)
namespace hostui {
void post(std::function<void()> fn) { dispatch_async(dispatch_get_main_queue(), ^{ fn(); }); }
void choose_file(const char*, const char*, bool, std::function<void(std::string)>) { LOG("[visionos] no file panel yet"); }
void choose_mod_source(bool, std::function<void(std::string)>) { LOG("[visionos] no file panel yet"); }
void choose_game_source(bool, std::function<void(std::string)>) { LOG("[visionos] no file panel yet"); }
bool get(const char* key, std::string& value) { return gfx::host_setting(key, value); }
void set(const char* key, const std::string& value) { gfx::set_host_setting(key, value); }
float res_scale() { return render::res_scale(); }
void set_res_scale(float s) {
    render::set_res_scale(s);
    gfx::save_graphics_options();
}
void graphics_changed() { gfx::save_graphics_options(); }
int scale_filter() { return gfx::g_filter; }
void set_scale_filter(int f) { gfx::g_filter = std::clamp(f, 0, 2); gfx::save_display_options(); }
bool scale_filter_available() { return true; }
bool fullscreen() { return true; }
void set_fullscreen(bool) {}
int drc_modes() { return gfx::kDrcModeCount; }
// window: the GamePad window (picture-in-picture while it is closed)
bool drc_mode_offered(int m) { return m >= 0 && m < gfx::kDrcModeCount; }
int drc_mode() { return gfx::g_mode; }
void set_drc_mode(int m) {
    if (!drc_mode_offered(m)) return;
    gfx::display_set_mode(m);
    gfx::save_display_options();
}
void save_pip_position() { gfx::save_display_options(); }
int pip_anchor() { return gfx::g_pip_anchor; }
void set_pip_anchor(int c) { gfx::g_pip_anchor = std::clamp(c, 0, int(gfx::kPipCustom)); gfx::save_display_options(); }
float pip_size() { return gfx::g_pip_size; }
void set_pip_size(float s) { gfx::g_pip_size = gfx::pip_clamp_size(s); gfx::save_display_options(); }
float pip_opacity() { return gfx::g_pip_opacity; }
void set_pip_opacity(float o) { gfx::g_pip_opacity = gfx::pip_clamp_opacity(o); gfx::save_display_options(); }
bool drc_available() { return true; }
bool drc_shown() { return gfx::drc_screen_shown(gfx::g_has_drc_window); }
void show_drc(bool on) { gfx::display_show_drc(on); }
void set_pro_controller(bool on) {
    input::set_pro_controller(on);
    gfx::display_show_drc(!on);
}
const char* name() { return "visionOS"; }
void set_clipboard(const std::string& text) { UIPasteboard.generalPasteboard.string = @(text.c_str()); }
bool can_open_folder() { return false; }
void open_folder(const std::string&) {}
void quit() { exit(0); }
}  // namespace hostui

// ---------------------------------------------------------------- mouse camera (mods/mouse.mm): no mouse
namespace mods {
bool mouse_captured() { return false; }
void mouse_release() {}
}  // namespace mods

// ---------------------------------------------------------------- game controllers (as input.mm)
namespace input {

static std::mutex g_mu;
static PadState g_pad;
static float g_host_values[input_map::kPadCount];
static bool g_touch;
static float g_tx, g_ty;
static std::atomic<bool> g_pro{false};
static std::atomic<void (*)(bool)> g_controller_listener{nullptr};

void set_touch(bool down, float x, float y) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_touch = down;
    g_tx = x;
    g_ty = y;
}

void mouse_binding_button(uint64_t, int, bool, bool) {}
void mouse_binding_wheel(float, bool) {}
void release_mouse_bindings() {}
bool gameplay_focused() { return true; }
void release_keys() {}
void held_keys(bool* keys) { std::fill(keys, keys + 256, false); }
bool has_rumble() { return false; }
void stop_rumble_now() {}
bool pro_controller() { return g_pro.load(std::memory_order_relaxed); }
void set_controller_listener(void (*fn)(bool pro)) { g_controller_listener = fn; }
void set_pro_controller(bool on) {
    const bool was = g_pro.exchange(on);
    LOG("[input] controller acts as %s", on ? "Pro Controller" : "GamePad");
    if (was != on)
        if (auto fn = g_controller_listener.load()) fn(on);
}

// every mappable input of one controller, 0..1; false: not a gamepad
static bool device_values(GCController* c, float* v) {
    using namespace input_map;
    for (int i = 0; i < kPadCount; i++) v[i] = 0;
    GCExtendedGamepad* g = c.extendedGamepad;
    if (!g) return false;
    auto put = [&](int p, float x) { if (x > v[p]) v[p] = x; };
    const auto layout = apple_face_layout(c.productCategory.UTF8String, c.vendorName.UTF8String);
    auto b = [&](GCControllerButtonInput* in, int p) {
        if (in) put(apple_face_input(layout, p), in.isPressed ? std::max(in.value, 0.51f) : std::min(in.value, 0.5f));
    };
    b(g.buttonA, kPadA); b(g.buttonB, kPadB); b(g.buttonX, kPadX); b(g.buttonY, kPadY);
    b(g.leftShoulder, kPadLB); b(g.rightShoulder, kPadRB);
    b(g.leftTrigger, kPadLT); b(g.rightTrigger, kPadRT);
    b(g.buttonMenu, kPadMenu); b(g.buttonOptions, kPadOptions); b(g.buttonHome, kPadHome);
    b(g.leftThumbstickButton, kPadL3); b(g.rightThumbstickButton, kPadR3);
    b(g.dpad.up, kPadDUp); b(g.dpad.down, kPadDDown); b(g.dpad.left, kPadDLeft); b(g.dpad.right, kPadDRight);
    auto stick = [&](GCControllerDirectionPad* d, int up, int down, int left, int right) {
        float x = d.xAxis.value, y = d.yAxis.value;
        put(right, std::max(x, 0.f)); put(left, std::max(-x, 0.f));
        put(up, std::max(y, 0.f)); put(down, std::max(-y, 0.f));
    };
    stick(g.leftThumbstick, kPadLSUp, kPadLSDown, kPadLSLeft, kPadLSRight);
    stick(g.rightThumbstick, kPadRSUp, kPadRSDown, kPadRSLeft, kPadRSRight);
    return true;
}

static std::vector<std::pair<uintptr_t, overlay::PadValues>> devices_values() {
    std::vector<std::pair<uintptr_t, overlay::PadValues>> out;
    for (GCController* c in [GCController controllers]) {
        overlay::PadValues d;
        if (device_values(c, d.data())) out.emplace_back((uintptr_t)(__bridge void*)c, d);
    }
    return out;
}

void controller_values(float* v) {
    using namespace input_map;
    for (int i = 0; i < kPadCount; i++) v[i] = 0;
    for (const auto& [id, d] : devices_values())
        for (int p = 0; p < kPadCount; p++) v[p] = std::max(v[p], d[p]);
}
void host_controller_values(float* v) {
    std::lock_guard<std::mutex> lk(g_mu);
    std::copy(g_host_values, g_host_values + input_map::kPadCount, v);
}

void init() {
    input_map::load_startup();
    auto describe = [](GCController* c, const char* what) {
        LOG("[input] controller %s: %s (%s), extended gamepad %s, face layout %d", what, c.vendorName.UTF8String ?: "?",
            c.productCategory.UTF8String ?: "?", c.extendedGamepad ? "yes" : "no",
            (int)input_map::apple_face_layout(c.productCategory.UTF8String, c.vendorName.UTF8String));
    };
    for (GCController* c in [GCController controllers]) describe(c, "present");
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification* n) { describe(n.object, "connected"); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification* n) { describe(n.object, "disconnected"); }];
    // debug: WWHD_LOG_BUTTONS=1 logs every change of the GamePad buttons the controllers produce
    static const bool log_buttons = getenv("WWHD_LOG_BUTTONS") != nullptr;
    // GameController values are polled on the main thread
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 240 repeats:YES block:^(NSTimer*) {
        float v[input_map::kPadCount], game[input_map::kPadCount];
        static overlay::DeviceGates<uintptr_t> gates;
        gates.combine(devices_values(), overlay::captures() || overlay::shortcut_took_input(), v, game);
        // − or + pressed while the TV window is closed: the app opens it again (WindWakerVisionApp.swift);
        // that press (until released) neither toggles Settings nor reaches the game
        static bool held_for_window[2];
        const int window_buttons[2] = {input_map::kPadOptions, input_map::kPadMenu};
        for (int i = 0; i < 2; i++) {
            const int b = window_buttons[i];
            const bool down = v[b] > 0.5f;
            if (down && !g_tv_open.load()) held_for_window[i] = true;
            if (!down) held_for_window[i] = false;
            if (held_for_window[i]) v[b] = game[b] = 0;
        }
        input_map::consume_shortcut_buttons(input_map::current(), v, game);
        PadState s = input_map::controller_state(input_map::current(), game);
        static uint32_t last_buttons = 0;
        if (log_buttons && s.buttons != last_buttons) {
            LOG("[input] buttons %04X (stick L %.2f %.2f, R %.2f %.2f)", s.buttons, s.lx, s.ly, s.rx, s.ry);
            last_buttons = s.buttons;
        }
        {
            std::lock_guard<std::mutex> lk(g_mu);
            g_pad = s;
            std::copy(v, v + input_map::kPadCount, g_host_values);
        }
        visionos::text_input_poll();
    }];
}

PadState read() {
    PadState s;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        s = g_pad;
        s.touch = g_touch;
        s.tx = g_tx;
        s.ty = g_ty;
    }
    mods::filter_pad(s);
    if (overlay::blocks_input()) {
        mods::quick_use_reset();
        s = PadState{};
    } else {
        mods::quick_use_filter_pad(s);
    }
    return s;
}

}  // namespace input

// ---------------------------------------------------------------- the GamePad window (the app's calls)
extern "C" void wwhd_visionos_set_drc_layer(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    if (l) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        l.colorspace = cs;
        CGColorSpaceRelease(cs);
        l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.framebufferOnly = YES;
        l.maximumDrawableCount = 3;
    }
    {
        std::lock_guard<std::mutex> lk(g_drc_mu);
        g_drc_layer = l;
    }
    gfx::g_has_drc_window = l != nil;
    LOG("[visionos] GamePad window %s", l ? "open" : "closed");
}

extern "C" void wwhd_visionos_set_drc_drawable_size(double w, double h, double scale) {
    std::lock_guard<std::mutex> lk(g_drc_mu);
    if (!g_drc_layer) return;
    g_drc_layer.contentsScale = scale;
    g_drc_layer.drawableSize = CGSizeMake(std::max(1.0, w * scale), std::max(1.0, h * scale));
}

// a touch at (x, y) in a w x h view (points): the GamePad picture is letterboxed to its aspect in it
extern "C" void wwhd_visionos_drc_touch(int down, double x, double y, double w, double h) {
    if (w <= 0 || h <= 0) return;
    const double a = gfx::g_drc_aspect;
    double x0 = 0, y0 = 0, pw = w, ph = h;
    if (w / h > a) { x0 = (w - h * a) / 2; pw = h * a; } else { y0 = (h - w / a) / 2; ph = w / a; }
    input::set_touch(down != 0, (float)std::clamp((x - x0) / pw, 0.0, 1.0), (float)std::clamp((y - y0) / ph, 0.0, 1.0));
}

extern "C" void wwhd_visionos_toggle_settings() { overlay::set_open(!overlay::is_open(), overlay::OpenReason::API); }

// which version of the game this app's recompiled code is (the app checks an imported game against it)
extern "C" const char* wwhd_visionos_build_name() { return g_guest_build_name; }
extern "C" const char* wwhd_visionos_build_title_id() { return g_guest_build_title_id; }

// the first start's shader preparation (main.cpp): 1 while it runs, with how far it is (0..1)
extern "C" int wwhd_visionos_shader_progress(double* fraction) {
    const size_t total = warmprogress::latest_total.load(), done = warmprogress::latest_done.load();
    if (fraction) *fraction = total ? double(done) / double(total) : 0.0;
    return total && done < total ? 1 : 0;
}
