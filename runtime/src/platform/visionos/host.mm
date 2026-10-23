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
#if __has_include(<MetalFX/MetalFX.h>)  // (the visionOS simulator has no MetalFX: no upscaling there)
#import <MetalFX/MetalFX.h>
#define WWHD_METALFX 1
#endif
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>

#include <algorithm>
#include <atomic>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <tuple>

#include "gfx/display.h"
#include "gfx/display_modes.h"
#include "gfx/metal.h"
#include "gfx/renderer.h"
#include "gfx/depth3d.h"
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
bool theater_size(int& w, int& h);      // theater.mm
bool theater_frame(const std::function<void(id<MTLTexture>)>& compose, id<MTLCommandBuffer> cb);
void theater_init();
}
static std::atomic<float> g_tv_density{2.0f};  // the TV window's display scale (the overlay's density there)
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
    g_tv_density = (float)scale;
    int tw, th;
    if (!visionos::theater_size(tw, th)) overlay::set_density((float)scale);
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
// depth-based 3D (gfx/depth3d.h): one eye's picture. Each pixel shows the picture `eye` (-1 left, +1 right)
// half a disparity to the side. The disparity grows with the depth buffer value (linear in it, as 1 /
// distance is) from 0 at `zc[0]`, the nearest depth near the centre smoothed over time (depth3d_focus), to
// `far` at infinity: everything sits at or behind the screen, nothing comes out of it. The depth is read
// without filtering and widened by a pixel toward the nearer side, so an outline stays with its object; a
// pixel that the shift uncovers takes the farther (background) side. Where the final picture differs from
// the scene without the HUD (`scene`) the HUD is: kept in place.
struct D3 { float far_; float eye; float hud; int scene; float texel; };
static float d3_depth(depth2d<float> dep, float2 uv, float texel) {
    constexpr sampler pt(coord::normalized, filter::nearest, address::clamp_to_edge);
    float z = dep.sample(pt, uv);
    z = min(z, dep.sample(pt, uv + float2(texel, 0)));
    z = min(z, dep.sample(pt, uv - float2(texel, 0)));
    return z;
}
static float d3_disparity(float z, float zc, float far_) { return clamp((z - zc) / max(1.0 - zc, 1e-4), 0.0, 1.0) * far_; }
kernel void depth3d_focus(depth2d<float> dep [[texture(0)]], device float* zc [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    if (id != 0) return;
    constexpr sampler pt(coord::normalized, filter::nearest, address::clamp_to_edge);
    float m = 1.0;
    for (int i = 0; i < 25; i++) m = min(m, dep.sample(pt, float2(0.3 + 0.1 * float(i % 5), 0.3 + 0.1 * float(i / 5))));
    m = min(m, 0.9995);
    zc[0] = zc[1] == 0.0 ? m : mix(zc[0], m, 0.05);  // (zc[1]: set once there is a value)
    zc[1] = 1.0;
}
fragment float4 depth3d_fs(VOut in [[stage_in]], texture2d<float> fin [[texture(0)]], texture2d<float> scene [[texture(1)]],
                           depth2d<float> dep [[texture(2)]], sampler s [[sampler(0)]], constant D3& p [[buffer(0)]],
                           device const float* zc [[buffer(1)]]) {
    float2 uv = in.uv;
    float x = uv.x;
    for (int it = 0; it < 4; it++) x = uv.x - p.eye * 0.5 * d3_disparity(d3_depth(dep, float2(x, uv.y), p.texel), zc[0], p.far_);
    // uncovered background: of the source and a pixel further toward the eye's side, the farther one
    float2 src = float2(x, uv.y), side = float2(x - p.eye * 2.0 * p.texel, uv.y);
    if (d3_depth(dep, side, p.texel) > d3_depth(dep, src, p.texel) + 0.0005) src = side;
    if (p.scene == 0) return fin.sample(s, src);
    float4 f0 = fin.sample(s, uv), s0 = scene.sample(s, uv);
    if (distance(f0.rgb, s0.rgb) > p.hud) return f0;
    float4 f1 = fin.sample(s, src), s1 = scene.sample(s, src);
    return distance(f1.rgb, s1.rgb) > p.hud ? s1 : f1;
}
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
// ---------------------------------------------------------------- MetalFX upscaling (Vision Pro > Picture)
// The TV picture enlarged to the pixels it covers (the window's drawable, the Full Screen texture) by
// MetalFX's spatial scaler instead of the presentation's filter: sharper edges at the same internal
// resolution, for a fraction of a millisecond. Only when that is larger than the picture; the scaler and
// its output are kept until the sizes change. Unsupported device or format: the picture as before.
std::atomic<bool> g_metalfx{false};
// what the last frame did, for the Vision Pro tab: input and output sizes (0: the picture was not upscaled)
std::atomic<int> g_metalfx_in_w{0}, g_metalfx_in_h{0}, g_metalfx_out_w{0}, g_metalfx_out_h{0};
#ifdef WWHD_METALFX
static id<MTLFXSpatialScaler> g_scaler;
static id<MTLTexture> g_scaled;
#endif

static id<MTLTexture> upscaled(id<MTLTexture> src, bool linear, int ow, int oh) {
    g_metalfx_out_w = 0;
#ifndef WWHD_METALFX
    (void)linear, (void)ow, (void)oh;
    return src;
#else
    if (!g_metalfx.load() || !src || (ow <= (int)src.width + 1 && oh <= (int)src.height + 1)) return src;
    static bool unsupported = false;
    if (unsupported) return src;
    if (!g_scaler || g_scaler.inputWidth != src.width || g_scaler.inputHeight != src.height || g_scaler.outputWidth != (NSUInteger)ow ||
        g_scaler.outputHeight != (NSUInteger)oh || g_scaler.colorTextureFormat != src.pixelFormat) {
        g_scaler = nil;
        g_scaled = nil;
        if (![MTLFXSpatialScalerDescriptor supportsDevice:R.device]) {
            unsupported = true;
            LOG("[visionos] MetalFX upscaling: not supported on this device");
            return src;
        }
        MTLFXSpatialScalerDescriptor* d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = src.width;
        d.inputHeight = src.height;
        d.outputWidth = ow;
        d.outputHeight = oh;
        d.colorTextureFormat = src.pixelFormat;
        d.outputTextureFormat = src.pixelFormat;
        d.colorProcessingMode = linear ? MTLFXSpatialScalerColorProcessingModeLinear : MTLFXSpatialScalerColorProcessingModePerceptual;
        g_scaler = [d newSpatialScalerWithDevice:R.device];
        if (!g_scaler || (g_scaler.colorTextureUsage & ~src.usage)) {
            LOG("[visionos] MetalFX upscaling: no scaler for %lux%lu format %d", (unsigned long)src.width, (unsigned long)src.height,
                (int)src.pixelFormat);
            g_scaler = nil;
            unsupported = true;
            return src;
        }
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:ow height:oh mipmapped:NO];
        td.usage = g_scaler.outputTextureUsage | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        g_scaled = [R.device newTextureWithDescriptor:td];
        LOG("[visionos] MetalFX upscaling %lux%lu -> %dx%d", (unsigned long)src.width, (unsigned long)src.height, ow, oh);
    }
    g_scaler.colorTexture = src;
    g_scaler.outputTexture = g_scaled;
    g_scaler.inputContentWidth = src.width;
    g_scaler.inputContentHeight = src.height;
    [g_scaler encodeToCommandBuffer:command_buffer()];
    g_metalfx_in_w = (int)src.width;
    g_metalfx_in_h = (int)src.height;
    g_metalfx_out_h = oh;
    g_metalfx_out_w = ow;
    return g_scaled;
#endif
}

static void compose_tv(id<MTLTexture> target, const Layout& L) {
    // MetalFX first (its own pass): then the picture is drawn 1:1
    id<MTLTexture> tv = upscaled(R.tv.tex, R.tv.srgb, (int)lroundf(L.tv.w), (int)lroundf(L.tv.h));
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    float dw = target.width, dh = target.height;
    MTLPixelFormat fmt = target.pixelFormat;
    draw_image(e, fmt, dw, dh, tv, R.tv.srgb, L.tv, 1.0f, tv == R.tv.tex ? R.tv.dyn : 1.0f);
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

// ---------------------------------------------------------------- depth-based 3D (gfx/depth3d.h)
// In Full Screen with 3D on the screen texture is two pictures wide: the left eye's, then the right
// eye's (its material shows each eye its half: StereoScreen.usda). The eyes come from the TV picture and
// the scene's depth (metal_draw.mm); the GamePad picture and the settings overlay are drawn flat in both.
bool depth3d_scene(__strong id<MTLTexture>& depth, __strong id<MTLTexture>& color);  // metal_draw.mm
static id<MTLTexture> g_eye[2];

static id<MTLRenderPipelineState> depth3d_pipeline(MTLPixelFormat fmt) {
    static id<MTLRenderPipelineState> p;
    static MTLPixelFormat made = MTLPixelFormatInvalid;
    if (p && made == fmt) return p;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_lib newFunctionWithName:@"present_vs"];
    d.fragmentFunction = [g_lib newFunctionWithName:@"depth3d_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    NSError* err = nil;
    p = [R.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) LOG("[3d] eye pipeline: %s", err.localizedDescription.UTF8String);
    made = fmt;
    return p;
}

// the two eye pictures of this frame (same size and format as the TV picture); false: no scene depth
static bool make_eyes() {
    id<MTLTexture> depth = nil, scene = nil;
    id<MTLTexture> tv = R.tv.tex;
    if (!tv || !depth3d_scene(depth, scene) || !depth) return false;
    id<MTLRenderPipelineState> pipe = depth3d_pipeline(tv.pixelFormat);
    if (!pipe) return false;
    static bool logged = false;
    if (!logged) {
        logged = true;
        LOG("[3d] eyes from %lux%lu (format %d), depth %lux%lu, scene without HUD %s", (unsigned long)tv.width,
            (unsigned long)tv.height, (int)tv.pixelFormat, (unsigned long)depth.width, (unsigned long)depth.height,
            scene ? (scene.pixelFormat == tv.pixelFormat ? "yes" : "yes (other format)") : "no");
    }
    // the focus depth, smoothed on the GPU (depth3d_focus)
    static id<MTLComputePipelineState> focus;
    static id<MTLBuffer> zc;
    if (!focus) {
        NSError* err = nil;
        focus = [R.device newComputePipelineStateWithFunction:[g_lib newFunctionWithName:@"depth3d_focus"] error:&err];
        zc = [R.device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        memset(zc.contents, 0, 16);  // (no value yet: the first frame takes its own)
        if (!focus) LOG("[3d] focus kernel: %s", err.localizedDescription.UTF8String);
    }
    if (!focus) return false;
    id<MTLComputeCommandEncoder> ce = [command_buffer() computeCommandEncoder];
    [ce setComputePipelineState:focus];
    [ce setTexture:depth atIndex:0];
    [ce setBuffer:zc offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [ce endEncoding];
    const float strength = std::clamp(depth3d::strength.load(), 0.0f, 1.0f);
    for (int e = 0; e < 2; e++) {
        if (!g_eye[e] || g_eye[e].width != tv.width || g_eye[e].height != tv.height || g_eye[e].pixelFormat != tv.pixelFormat) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:tv.pixelFormat width:tv.width
                                                                                          height:tv.height mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            g_eye[e] = [R.device newTextureWithDescriptor:td];
        }
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = g_eye[e];
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [command_buffer() renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipe];
        float rect[4] = {0, 0, 1, 1};
        // at most 0.8 % of the width between the eyes at infinity (Depth 1)
        struct { float far_, eye, hud; int scene; float texel; } p = {0.008f * strength,
                                                                      (e == 0 ? -1.0f : 1.0f) * (depth3d::swap.load() ? -1.0f : 1.0f), 0.08f,
                                                                      scene && scene.pixelFormat == tv.pixelFormat ? 1 : 0,
                                                                      1.0f / float(depth.width)};
        [enc setVertexBytes:rect length:sizeof rect atIndex:0];
        [enc setFragmentTexture:tv atIndex:0];
        [enc setFragmentTexture:scene ? scene : tv atIndex:1];
        [enc setFragmentTexture:depth atIndex:2];
        [enc setFragmentSamplerState:R.linearClamp atIndex:0];
        [enc setFragmentBytes:&p length:sizeof p atIndex:0];
        [enc setFragmentBuffer:zc offset:0 atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
    }
    return true;
}

// an overlay draw list made for one half of the target, drawn into half `half` (0 left, 1 right) of it
static void draw_imgui_half(ImDrawData* d, MTLRenderPassDescriptor* rp, id<MTLRenderCommandEncoder> e, int half) {
    const ImVec2 pos = d->DisplayPos, size = d->DisplaySize;
    d->DisplaySize.x = size.x * 2;
    if (half) d->DisplayPos.x = pos.x - size.x;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui_ImplMetal_RenderDrawData(d, command_buffer(), e);
    d->DisplayPos = pos;
    d->DisplaySize = size;
}

// the side-by-side Full Screen picture; L is laid out for one half
// While 3D is shown "depth3dShown" is saved as 1 (leaving 3D or the app leaving the front saves 0): a start
// that finds 1 follows a crash in 3D, and starts with 3D off (load_graphics_options).
std::atomic<bool> g_d3_marked{false};
static void mark_3d_shown(bool shown) {
    if (g_d3_marked.exchange(shown) == shown) return;
    [[NSUserDefaults standardUserDefaults] setObject:shown ? @"1" : @"0" forKey:@"wwhd.depth3dShown"];
}

static void compose_tv_sbs(id<MTLTexture> target, const Layout& L) {
    mark_3d_shown(true);
    const bool eyes = make_eyes();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    const float dw = target.width, dh = target.height, half = dw / 2;
    const MTLPixelFormat fmt = target.pixelFormat;
    for (int i = 0; i < 2; i++) {
        Box b = L.tv;
        b.x += i * half;
        draw_image(e, fmt, dw, dh, eyes ? g_eye[i] : R.tv.tex, R.tv.srgb, b, 1.0f, R.tv.dyn);
    }
    ImDrawData* hud = nullptr;
    float op = 1;
    if (L.pip_on && R.drc.tex) {
        op = L.drc_only ? 1.0f : g_pip_opacity.load();
        const float bw = std::max(1.0f, roundf(L.pip.w / 200.0f));
        float frame[4] = {0, 0, 0, 0.6f * op};
        for (int i = 0; i < 2; i++) {
            draw_solid(e, fmt, dw, dh, {L.pip.x - bw + i * half, L.pip.y - bw, L.pip.w + 2 * bw, L.pip.h + 2 * bw}, frame);
            draw_image(e, fmt, dw, dh, R.drc.tex, R.drc.srgb, {L.pip.x + i * half, L.pip.y, L.pip.w, L.pip.h}, op, R.drc.dyn);
        }
        if ((hud = overlay::guesthud::gamepad_region(half, dh, L.pip.x, L.pip.y, L.pip.w, L.pip.h, op)) && is_srgb(fmt))
            overlay::linearize_colors(hud, true);
    }
    if (hud)
        for (int i = 0; i < 2; i++) draw_imgui_half(hud, rp, e, i);
    if (g_overlay_draw) {
        if (is_srgb(fmt)) overlay::linearize_colors(g_overlay_draw);
        for (int i = 0; i < 2; i++) draw_imgui_half(g_overlay_draw, rp, e, i);
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
    set_float("metalFX", g_metalfx.load());
    set_float("depth3d", depth3d::enabled.load());
    set_float("depth3dStrength", depth3d::strength.load());
    set_float("depth3dSwap", depth3d::swap.load());
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
    if (saved_float("metalFX", v)) g_metalfx = v != 0;
    if (saved_float("depth3d", v)) depth3d::enabled = v != 0;
    std::string shown;
    if (host_setting("depth3dShown", shown) && shown == "1" && depth3d::enabled.load()) {
        depth3d::enabled = false;  // the last run ended while 3D was showing (a crash): start without it
        set_host_setting("depth3dShown", "0");
        set_float("depth3d", 0);
        LOG("[3d] the last run ended while 3D was shown: 3D is off this time (Settings > Vision Pro to turn it on)");
    }
    if (saved_float("depth3dStrength", v)) depth3d::strength = std::clamp(v, 0.0f, 1.0f);
    if (saved_float("depth3dSwap", v)) depth3d::swap = v != 0;
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
    if (gfx::g_d3_marked.exchange(false)) set_host_setting("depth3dShown", "0");  // (left the front normally)
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
    visionos::theater_init();
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
    // while the TV window is closed the overlay keeps the size it last had (it still runs: text prompt);
    // in theater mode the picture goes to the theater screen's texture, at its size (theater.mm)
    static CGSize last_size = CGSizeMake(1920, 1080);
    if (tv) last_size = tv.drawableSize;
    CGSize ls = last_size;
    int theater_w = 0, theater_h = 0;
    const bool theater = visionos::theater_size(theater_w, theater_h);
    // (3D: the texture holds both eyes side by side; the layout is one eye's)
    const bool sbs = theater && depth3d::enabled.load() && theater_w >= 2 * theater_h;
    if (!sbs && g_d3_marked.load()) mark_3d_shown(false);
    if (theater) ls = CGSizeMake(sbs ? theater_w / 2 : theater_w, theater_h);
    static bool was_theater = false;
    if (theater != was_theater) {  // the overlay as large on the screen as in the window (720 points high there)
        was_theater = theater;
        overlay::set_density(theater ? theater_h / 720.0f : g_tv_density.load());
    }
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
    if (theater) {
        visionos::theater_frame([&](id<MTLTexture> target) { sbs ? compose_tv_sbs(target, L) : compose_tv(target, L); }, command_buffer());
    } else if (tv && scr.tex) {
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
            int tw, th;
            if (down && !g_tv_open.load() && !visionos::theater_size(tw, th)) held_for_window[i] = true;
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

// the TV picture's size at the full internal resolution (0 x 0 before the first frame): Full Screen sizes
// its screen texture from it
extern "C" void wwhd_visionos_tv_picture_size(int* width, int* height) {
    *width = (int)gfx::nominal_w(gfx::R.tv);
    *height = (int)gfx::nominal_h(gfx::R.tv);
}

// 3D (gfx/depth3d.h) is on: Full Screen then sizes its texture for two eyes and uses the per-eye material
extern "C" int wwhd_visionos_depth3d(void) { return depth3d::enabled.load() ? 1 : 0; }
