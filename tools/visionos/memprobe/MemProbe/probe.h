#ifndef PROBE_H
#define PROBE_H
#include <stdint.h>

typedef struct {
    int fixed_kr;          // mach_vm_allocate 4 GB, VM_FLAGS_FIXED at 0x1000000000 (as core.cpp mem::init)
    int fixed_touch_ok;    // first and last byte of the region writable
    int anywhere_kr;       // mach_vm_allocate 4 GB, VM_FLAGS_ANYWHERE
    uint64_t anywhere_addr;
    int anywhere_touch_ok;
    int vm_fixed_kr;       // vm_allocate (public header) 4 GB, VM_FLAGS_FIXED at 0x1000000000
    uint64_t mmap_addr;    // mmap 4 GB with hint 0x1000000000 (core.cpp non-Apple path); 0 = MAP_FAILED
    int mmap_errno;
    uint64_t cand_addr[5]; // further VM_FLAGS_FIXED 4 GB candidates (macOS base, above the guard, ...)
    int cand_kr[5];
    int cand_touch_ok[5];
    uint64_t largest_anywhere_mb; // largest ANYWHERE allocation that succeeded (power-of-two ladder)
} probe_result;

probe_result run_probe(void);
const char* probe_kr_string(int kr);

#endif
