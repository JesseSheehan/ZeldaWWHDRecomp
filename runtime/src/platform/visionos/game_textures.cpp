// visionOS host: textures from the player's own game files, for the app's Full Screen scenery (the sea's
// waves, the sky's clouds, the sun: visionos/WindWakerVision/WindWakerVision/GameScenery.swift). Read on
// the device from the imported game folder when Full Screen opens; nothing from the game is in the app.
//
// A texture is found by name in a BFRES (Wii U, version 3) inside an archive: Yaz0 and SARC layers are
// opened down to it, keeping to the members named on the way. Mip 0 is untiled with LatteAddrLib (as
// game_glyph.cpp does from guest memory) and BC1-5 decoded to RGBA8 on the CPU.
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "Cafe/HW/Latte/LatteAddrLib/LatteAddrLib.h"
#include "gfx/vulkan/bc_reference.h"
#include "mods/item_icons.h"
#include "runtime.h"

namespace {

using Bytes = std::vector<uint8_t>;

uint32_t be32(const Bytes& b, size_t o) { return o + 4 <= b.size() ? uint32_t(b[o]) << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3] : 0; }
int32_t rel(const Bytes& b, size_t o) { return int32_t(be32(b, o)); }  // a self-relative offset field

bool magic(const Bytes& b, const char* m) { return b.size() >= 4 && std::memcmp(b.data(), m, 4) == 0; }

// the BFRES's texture `name` (its FTEX offset), or 0
size_t find_ftex(const Bytes& fres, const std::string& name) {
    const size_t group = 0x24 + size_t(rel(fres, 0x24));
    if (group == 0x24 || group + 8 > fres.size()) return 0;
    const int32_t count = rel(fres, group + 4);
    for (int32_t i = 1; i <= count && i < 4096; i++) {
        const size_t e = group + 8 + 16 * size_t(i);
        if (e + 16 > fres.size()) return 0;
        const size_t name_at = e + 8 + size_t(rel(fres, e + 8)), data_at = e + 12 + size_t(rel(fres, e + 12));
        if (name_at >= fres.size()) continue;
        const char* s = (const char*)fres.data() + name_at;
        if (strnlen(s, fres.size() - name_at) == name.size() && name == s) return data_at;
    }
    return 0;
}

// mip 0 of the FTEX at `t`, as RGBA8 (after its component selection); empty if unsupported
Bytes decode_ftex(const Bytes& f, size_t t, uint32_t& width, uint32_t& height) {
    if (t + 0xB8 > f.size() || std::memcmp(f.data() + t, "FTEX", 4)) return {};
    const uint32_t dim = be32(f, t + 4), depth = be32(f, t + 0x10), format = be32(f, t + 0x18), aa = be32(f, t + 0x1C);
    const uint32_t image_size = be32(f, t + 0x24), tile_mode = be32(f, t + 0x34), swizzle = be32(f, t + 0x38), select = be32(f, t + 0x88);
    width = be32(f, t + 8), height = be32(f, t + 0xC);
    const size_t image = t + 0xB0 + size_t(rel(f, t + 0xB0));
    const uint32_t fmt = format & 0x3F;
    const int bc = fmt >= 0x31 && fmt <= 0x35 ? int(fmt - 0x30) : 0;
    const uint32_t bytes = bc ? gfxvk::bc::block_bytes(bc) : fmt == 0x1A ? 4 : fmt == 1 ? 1 : 0;
    if (!bytes || !width || !height || width > 4096 || height > 4096 || image + image_size > f.size()) return {};
    LatteAddrLib::AddrSurfaceInfo_OUT geometry{};
    LatteAddrLib::GX2CalculateSurfaceInfo((Latte::E_GX2SURFFMT)format, width, height, depth ? depth : 1, (Latte::E_DIM)dim,
                                          (Latte::E_GX2TILEMODE)tile_mode, aa, 0, &geometry);
    const Latte::E_HWTILEMODE tile = geometry.hwTileMode;
    const uint32_t pitch = be32(f, t + 0x40) ? be32(f, t + 0x40) : geometry.pitch;
    LatteAddrLib::CachedSurfaceAddrInfo cached{};
    if (Latte::TM_IsMacroTiled(tile))
        LatteAddrLib::SetupCachedSurfaceAddrInfo(&cached, 0, 0, bytes * 8, pitch, geometry.height, geometry.depth, 1, tile, false,
                                                 (swizzle >> 8) & 1, (swizzle >> 9) & 3);
    Bytes out(size_t(width) * height * 4);
    for (uint32_t y = 0; y < height; y++)
        for (uint32_t x = 0; x < width; x++) {
            const uint32_t ex = bc ? x / 4 : x, ey = bc ? y / 4 : y;
            uint32_t offset;
            if (tile == Latte::E_HWTILEMODE::TM_LINEAR_GENERAL || tile == Latte::E_HWTILEMODE::TM_LINEAR_ALIGNED)
                offset = LatteAddrLib::ComputeSurfaceAddrFromCoordLinear(ex, ey, 0, 0, bytes * 8, pitch, geometry.height, geometry.depth);
            else if (!Latte::TM_IsMacroTiled(tile))
                offset = LatteAddrLib::ComputeSurfaceAddrFromCoordMicroTiled(ex, ey, 0, bytes * 8, pitch, geometry.height, tile, false);
            else
                offset = LatteAddrLib::ComputeSurfaceAddrFromCoordMacroTiledCached(ex, ey, &cached);
            if (uint64_t(offset) + bytes > image_size) continue;
            const uint8_t* p = f.data() + image + offset;
            std::array<uint8_t, 4> c{0, 0, 0, 255};
            if (bc) c = gfxvk::bc::pixel(p, unsigned(bc), false, (y % 4) * 4 + x % 4);
            else if (fmt == 1) c[0] = p[0];
            else std::memcpy(c.data(), p, 4);
            uint8_t* o = out.data() + (size_t(y) * width + x) * 4;
            for (int i = 0; i < 4; i++) {  // the texture's component selection (0..3 a channel, 4 zero, 5 one)
                const uint32_t m = (select >> (24 - 8 * i)) & 255;
                o[i] = m < 4 ? c[m] : m == 5 ? 255 : 0;
            }
        }
    return out;
}

// `data` opened through Yaz0 / SARC layers; in a SARC only the members named in `path` (any order) are
// entered, or every member when none is named; the first BFRES with the texture wins
Bytes find_texture(Bytes data, const std::vector<std::string>& path, const std::string& name, uint32_t& w, uint32_t& h, int depth = 0) {
    if (depth > 6) return {};
    if (magic(data, "Yaz0")) data = item_icons::yaz0_decode(data);
    if (magic(data, "FRES")) {
        const size_t t = find_ftex(data, name);
        return t ? decode_ftex(data, t, w, h) : Bytes{};
    }
    if (!magic(data, "SARC")) return {};
    for (auto& [member, bytes] : item_icons::read_sarc(data)) {
        bool named = path.empty();
        for (const auto& p : path) named |= member == p;
        if (!named) continue;
        Bytes found = find_texture(bytes, path, name, w, h, depth + 1);
        if (!found.empty()) return found;
    }
    return {};
}

}  // namespace

// A texture of the game as RGBA8 (malloc'd: free with wwhd_visionos_free), or NULL. `file` is relative to
// the game folder ("content/Common/Pack/permanent_3d.pack"), `members` the archive members to enter on the
// way ("Always.szs"; several separated by '/'; NULL or "" for all).
extern "C" uint8_t* wwhd_visionos_game_texture(const char* game_dir, const char* file, const char* members, const char* name, int* width,
                                               int* height) {
    try {
        std::ifstream in(std::string(game_dir) + "/" + file, std::ios::binary);
        if (!in) return nullptr;
        Bytes data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::vector<std::string> path;
        if (members && *members) {
            std::stringstream ss(members);
            for (std::string m; std::getline(ss, m, '/');)
                if (!m.empty()) path.push_back(m);
        }
        uint32_t w = 0, h = 0;
        Bytes rgba = find_texture(std::move(data), path, name, w, h);
        if (rgba.empty()) {
            LOG("[visionos] game texture %s not found in %s", name, file);
            return nullptr;
        }
        auto* out = (uint8_t*)std::malloc(rgba.size());
        std::memcpy(out, rgba.data(), rgba.size());
        *width = int(w);
        *height = int(h);
        return out;
    } catch (const std::exception& e) {
        LOG("[visionos] game texture %s from %s: %s", name, file, e.what());
        return nullptr;
    }
}

extern "C" void wwhd_visionos_free(void* p) { std::free(p); }
