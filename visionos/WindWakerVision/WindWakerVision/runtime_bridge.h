// The runtime's entry points for the app (runtime/src/platform/visionos/host.mm, runtime/src/main.cpp)
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
int wwhd_visionos_reserve_memory(void);
void wwhd_visionos_set_layer(void* layer);
void wwhd_visionos_set_drawable_size(double width, double height, double scale);
int wwhd_runtime_main(int argc, char** argv);
#ifdef __cplusplus
}
#endif
