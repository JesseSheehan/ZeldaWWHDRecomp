#include "probe.h"
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <sys/mman.h>

// <mach/mach_vm.h> is "#error mach_vm.h unsupported." in the visionOS SDKs, but libsystem_kernel
// still exports the symbols, so declare them as the macOS header does.
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t* address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address, mach_vm_size_t size);

#define GUEST_BASE 0x1000000000ull
#define GUEST_SIZE 0x100000000ull

static int touch(uint64_t a, uint64_t size) {
    volatile uint8_t* p = (volatile uint8_t*)a;
    p[0] = 0xA5; p[size - 1] = 0x5A;
    return p[0] == 0xA5 && p[size - 1] == 0x5A;
}

probe_result run_probe(void) {
    probe_result r = {0};

    mach_vm_address_t addr = GUEST_BASE;
    r.fixed_kr = mach_vm_allocate(mach_task_self(), &addr, GUEST_SIZE, VM_FLAGS_FIXED);
    if (r.fixed_kr == KERN_SUCCESS) {
        r.fixed_touch_ok = touch(addr, GUEST_SIZE);
        mach_vm_deallocate(mach_task_self(), addr, GUEST_SIZE);
    }

    addr = 0;
    r.anywhere_kr = mach_vm_allocate(mach_task_self(), &addr, GUEST_SIZE, VM_FLAGS_ANYWHERE);
    if (r.anywhere_kr == KERN_SUCCESS) {
        r.anywhere_addr = addr;
        r.anywhere_touch_ok = touch(addr, GUEST_SIZE);
        mach_vm_deallocate(mach_task_self(), addr, GUEST_SIZE);
    }

    vm_address_t va = GUEST_BASE;
    r.vm_fixed_kr = vm_allocate(mach_task_self(), &va, GUEST_SIZE, VM_FLAGS_FIXED);
    if (r.vm_fixed_kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), va, GUEST_SIZE);

    void* p = mmap((void*)GUEST_BASE, GUEST_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) r.mmap_errno = errno;
    else { r.mmap_addr = (uint64_t)p; munmap(p, GUEST_SIZE); }

    static const uint64_t cands[5] = {0x200000000000ull, 0x7000000000ull, 0x8000000000ull, 0x10000000000ull, 0x2000000000ull};
    for (int i = 0; i < 5; i++) {
        mach_vm_address_t a = cands[i];
        r.cand_addr[i] = a;
        r.cand_kr[i] = mach_vm_allocate(mach_task_self(), &a, GUEST_SIZE, VM_FLAGS_FIXED);
        if (r.cand_kr[i] == KERN_SUCCESS) {
            r.cand_touch_ok[i] = touch(a, GUEST_SIZE);
            mach_vm_deallocate(mach_task_self(), a, GUEST_SIZE);
        }
    }

    for (uint64_t mb = 64; mb <= 64 * 1024; mb *= 2) {
        mach_vm_address_t a = 0;
        if (mach_vm_allocate(mach_task_self(), &a, mb << 20, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) break;
        mach_vm_deallocate(mach_task_self(), a, mb << 20);
        r.largest_anywhere_mb = mb;
    }
    return r;
}

const char* probe_kr_string(int kr) { return mach_error_string(kr); }
