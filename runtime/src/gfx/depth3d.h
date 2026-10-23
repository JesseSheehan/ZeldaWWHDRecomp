// Depth-based 3D (visionOS: Settings > Vision Pro > 3D, platform/visionos/theater.mm): the game is drawn
// once; the presentation makes two eye pictures from it, each pixel shifted sideways by its depth. The
// HUD and menus stay at screen depth. Needs the scene's depth and its colour before the HUD: the Metal
// renderer copies both at the first layout (HUD) draw onto a target of the scene's size, once a frame
// (metal_draw.mm depth3d_track; nothing while off). The eye pictures: platform/visionos/host.mm.
#pragma once
#include <atomic>

namespace depth3d {
inline std::atomic<bool> enabled{false};
inline std::atomic<float> strength{0.5f};  // 0..1: the depth effect (1: 0.8 % of the width between the eyes at infinity)
inline std::atomic<bool> swap{false};      // left and right exchanged
}  // namespace depth3d
