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
#ifdef __cplusplus
}
#endif
