# MemProbe

A diagnostic visionOS app from the port's feasibility work: it tries to reserve the runtime's 4 GiB
guest address space at fixed addresses (and anywhere) and shows the results. It found that visionOS
keeps a guard over 0xFC0000000-0x7000000000 and rejects addresses at or above 0x8000000000, which is
why the runtime's visionOS guest base is 0x7000000000 (runtime/include/ppc.h).

Build configurations: Debug, and ExtendedVA (with the extended virtual addressing entitlement).
Signing comes from visionos/Local.xcconfig, as for the app (docs/visionos.md).
