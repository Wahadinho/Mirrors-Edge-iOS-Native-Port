#import <Metal/Metal.h>
#include "mtl_shader_compiler.h"
#include <cstdio>
#include <fstream>
#include <vector>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <vs.bin> <ps.bin>\n", argv[0]);
        return 1;
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "no Metal device\n"); return 2; }
    printf("Metal device: %s\n", [[dev name] UTF8String]);

    mtl_d3d9::MtlShaderCompiler compiler(dev);

    auto loadBin = [](const char *path) -> std::vector<uint32_t> {
        std::ifstream f(path, std::ios::binary | std::ios::ate);
        if (!f) return {};
        size_t sz = (size_t)f.tellg();
        f.seekg(0);
        std::vector<uint32_t> buf((sz + 3) / 4, 0);
        f.read(reinterpret_cast<char *>(buf.data()), sz);
        return buf;
    };

    auto vsBin = loadBin(argv[1]);
    auto psBin = loadBin(argv[2]);
    if (vsBin.empty() || psBin.empty()) { fprintf(stderr, "failed to load bins\n"); return 3; }

    auto vs = compiler.compileFromBytecode(vsBin.data(), true);
    if (!vs) { fprintf(stderr, "VS compile failed\n"); return 4; }
    printf("VS OK! inputs=%zu cbvMask=0x%x sampMask=0x%x\n",
           vs->vsInputs.size(), vs->defaultCompiled.usedCbvMask, vs->defaultCompiled.usedSamplerMask);
    for (auto &vi : vs->vsInputs) {
        printf("  vs in: loc=%u usage=%u idx=%u\n", vi.location, vi.usage, vi.usageIndex);
    }
    printf("===== VS MSL =====\n%s\n", vs->defaultCompiled.mslSource.c_str());

    auto ps = compiler.compileFromBytecode(psBin.data(), false);
    if (!ps) { fprintf(stderr, "PS parse failed\n"); return 5; }
    const auto *psComp = compiler.getOrCompilePsVariant(*ps, vs.get(), 0x1u, false, false, false, false, 0, 0, 0, 0);
    if (!psComp) { fprintf(stderr, "PS compile failed\n"); return 6; }
    printf("PS OK! cbvMask=0x%x constFVecs=%u sampMask=0x%x colorOut=0x%x depth=%d\n",
           psComp->usedCbvMask, psComp->constFloatVecCount, psComp->usedSamplerMask, psComp->colorOutputMask, psComp->writesDepth);
    printf("===== PS MSL =====\n%s\n", psComp->mslSource.c_str());
    return 0;
}
