// The guest address space (4 GiB at a fixed address) is reserved before main(), ahead of the system
// frameworks, which could otherwise map something there first.
#include <stdio.h>
#include "runtime_bridge.h"

__attribute__((constructor)) static void reserve_guest_memory(void) {
    int kr = wwhd_visionos_reserve_memory();
    fprintf(stderr, "[visionos] guest address space reservation: kr=%d\n", kr);
}
