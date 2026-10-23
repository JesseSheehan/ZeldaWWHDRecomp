// The runtime's entry points for the app (runtime/src/platform/visionos/host.mm, runtime/src/main.cpp)
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int wwhd_visionos_reserve_memory(void);
void wwhd_visionos_set_layer(void* layer);
void wwhd_visionos_set_drawable_size(double width, double height, double scale);
int wwhd_runtime_main(int argc, char** argv);
// the GamePad window: its layer (NULL when closed), size, touches (view points); the settings overlay
void wwhd_visionos_set_drc_layer(void* layer);
void wwhd_visionos_set_drc_drawable_size(double width, double height, double scale);
void wwhd_visionos_drc_touch(int down, double x, double y, double width, double height);
void wwhd_visionos_toggle_settings(void);
// the version of the game the app was built for: "USA", "EU", ...; its title id (16 hex digits)
const char* wwhd_visionos_build_name(void);
const char* wwhd_visionos_build_title_id(void);
// the first start's shader preparation: 1 while it runs, *fraction how far (0..1)
int wwhd_visionos_shader_progress(double* fraction);
// theater mode (theater.mm): the screen's texture, from a RealityKit DrawableQueue. next: the next texture
// (an id<MTLTexture>, not retained; NULL when none is free), called on the render thread; present: present
// it when the command buffer (an id<MTLCommandBuffer>) completes. NULLs: theater mode off.
typedef void* (*wwhd_theater_next_fn)(void);
typedef void (*wwhd_theater_present_fn)(void* command_buffer);
void wwhd_visionos_set_theater(wwhd_theater_next_fn next, wwhd_theater_present_fn present, int width, int height);
// the settings menu's Theater tab: action 0 enter (value 1) / leave (0), 1 screen size (0..2), 2 surroundings
// (0 sky, 1 dimmed room); called on the main thread. The app reports what shows with theater_state.
typedef void (*wwhd_theater_action_fn)(int action, int value);
void wwhd_visionos_set_theater_actions(wwhd_theater_action_fn fn);
void wwhd_visionos_theater_state(int active, int size, int environment);
#ifdef __cplusplus
}
#endif
