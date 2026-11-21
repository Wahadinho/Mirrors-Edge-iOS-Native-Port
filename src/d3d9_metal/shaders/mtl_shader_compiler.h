#pragma once

#import <Metal/Metal.h>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace mtl_d3d9 {

/* Deterministic Metal buffer slots: VS = 16 + cbvRegIndex, PS = cbvRegIndex */
static constexpr uint32_t kVsBufBase         = 16;
static constexpr uint32_t kVsBufConstFloat   = 16; /* reg 0: float4[256] */
static constexpr uint32_t kVsBufConstInt     = 17; /* reg 1: int4[16] */
static constexpr uint32_t kVsBufConstBool    = 18; /* reg 2: uint32[16] */
static constexpr uint32_t kVsBufFog          = 20; /* reg 4 */
static constexpr uint32_t kVsBufClipPlanes   = 21; /* reg 5 */
static constexpr uint32_t kVsBufPointArgs    = 22; /* reg 6 */
static constexpr uint32_t kVsBufSamplerState = 23; /* reg 7 */
static constexpr uint32_t kVsBufPosFixup     = 25; /* reg 9: float4(1/vpW, -1/vpH, 0, depthBias) */
static constexpr uint32_t kVsBufZeroAttr     = 26; /* 16-byte zero fallback for missing vertex attrs */

static constexpr uint32_t kPsBufConstFloat   = 0;  /* reg 0: float4[224] */
static constexpr uint32_t kPsBufConstInt     = 1;  /* reg 1: int4[16] */
static constexpr uint32_t kPsBufConstBool    = 2;  /* reg 2: uint32[16] */
static constexpr uint32_t kPsBufAlphaTest    = 3;  /* reg 3 */
static constexpr uint32_t kPsBufFog          = 4;  /* reg 4 */
static constexpr uint32_t kPsBufClipPlanes   = 5;  /* reg 5 */
static constexpr uint32_t kPsBufPointArgs    = 6;  /* reg 6 */
static constexpr uint32_t kPsBufSamplerState = 7;  /* reg 7 */
static constexpr uint32_t kPsBufTexStage     = 8;  /* reg 8 */

/* Matches dxbc_spv::ir::makeLegacy*Type() scalar-aligned layout byte-for-byte */
struct MtlAlphaTestCB {
    uint32_t compareOp;  /* D3DCMPFUNC - 1 (0=Never..7=Always) */
    uint32_t precision;  /* 0 for 8-bit UNORM targets, 9 (>8) for float targets */
    uint32_t alphaRef;   /* 0..255 */
    uint32_t _pad;
};
static_assert(sizeof(MtlAlphaTestCB) == 16, "MtlAlphaTestCB size");

struct MtlFogCB {
    uint32_t enable;
    uint32_t useZ;
    uint32_t mode;       /* 0=None, 1=Exp, 2=Exp2, 3=Linear */
    float    color[3];   /* offset 12 (packed_float3 in MSL) */
    float    distScale;  /* offset 24 */
    float    distEnd;    /* offset 28 */
    float    density;    /* offset 32 */
    uint32_t _pad;       /* round to 40 bytes */
};
static_assert(offsetof(MtlFogCB, color) == 12 && offsetof(MtlFogCB, density) == 32, "MtlFogCB layout");

struct MtlClipPlanesCB {
    uint32_t count;        /* offset 0 */
    float    planes[6][4]; /* offset 4 (packed_float4 x6 in MSL) */
    uint32_t _pad[3];      /* round to 112 bytes */
};
static_assert(offsetof(MtlClipPlanesCB, planes) == 4, "MtlClipPlanesCB layout");

struct MtlPointArgsCB {
    uint32_t isPointSprite;
    float    pointSize;
    float    pointSizeMin;
    float    pointSizeMax;
};
static_assert(sizeof(MtlPointArgsCB) == 16, "MtlPointArgsCB size");

struct MtlSamplerStateEntry {
    uint32_t textureType;     /* 0=2D, 1=3D, 2=Cube */
    uint32_t useDepthCompare; /* 0 or 1 */
    uint32_t useProjection;   /* 0 or 1 */
    uint32_t isNull;          /* 0 or 1 */
    uint32_t useGather;       /* 0 or 1 (Fetch4) */
    uint32_t drefClamp;       /* 0 or 1 */
    float    drefScale;       /* usually 1.0f */
};
static_assert(sizeof(MtlSamplerStateEntry) == 28, "MtlSamplerStateEntry size");

struct MtlTexStageEntry {
    float bumpMat0[2];
    float bumpMat1[2];
    float bumpScale;
    float bumpOffset;
};
static_assert(sizeof(MtlTexStageEntry) == 24, "MtlTexStageEntry size");

struct MtlPosFixupCB {
    float x;         /*  1.0f / vpWidth  */
    float y;         /* -1.0f / vpHeight */
    float z;         /* reserved (0.0f)  */
    float depthBias; /* clip-space bias  */
};
static_assert(sizeof(MtlPosFixupCB) == 16, "MtlPosFixupCB size");

struct MtlVertexInputSemantic {
    uint32_t location;
    uint8_t  usage;      /* D3DDECLUSAGE (0=Position, 1=BlendWeight, ..., 5=TexCoord, 10=Color...) */
    uint8_t  usageIndex;
};

enum class MtlSamplerTexKind : uint8_t {
    Tex2D   = 0,
    Tex3D   = 1,
    TexCube = 2,
};

struct MtlShaderVariantKey {
    uint64_t vsIoHash            = 0; /* 0 = default standalone PS */
    uint8_t  colorWriteMask      = 0xFu; /* bit i = RT i is bound and non-NULL */
    bool     hasDepthAttach      = true;
    bool     flatShade           = false;
    bool     alphaTestEnable     = false;
    bool     pointSpriteEnable   = false;
    uint16_t samplerDepthCmpMask = 0;
    uint16_t samplerNullMask     = 0;
    uint16_t samplerProjMask     = 0;
    uint16_t samplerGatherMask   = 0;

    bool operator==(const MtlShaderVariantKey &o) const {
        return vsIoHash == o.vsIoHash &&
               colorWriteMask == o.colorWriteMask &&
               hasDepthAttach == o.hasDepthAttach &&
               flatShade == o.flatShade &&
               alphaTestEnable == o.alphaTestEnable &&
               pointSpriteEnable == o.pointSpriteEnable &&
               samplerDepthCmpMask == o.samplerDepthCmpMask &&
               samplerNullMask == o.samplerNullMask &&
               samplerProjMask == o.samplerProjMask &&
               samplerGatherMask == o.samplerGatherMask;
    }
};

struct MtlShaderVariantKeyHash {
    size_t operator()(const MtlShaderVariantKey &k) const {
        size_t h = std::hash<uint64_t>()(k.vsIoHash);
        h ^= (size_t(k.colorWriteMask) << 1) | (size_t(k.hasDepthAttach) << 8) |
             (size_t(k.flatShade) << 9) | (size_t(k.alphaTestEnable) << 10) |
             (size_t(k.pointSpriteEnable) << 11);
        h ^= (size_t(k.samplerDepthCmpMask) << 12) ^ (size_t(k.samplerNullMask) << 28) ^
             (size_t(k.samplerProjMask) << 44) ^ (size_t(k.samplerGatherMask) << 20);
        return h;
    }
};

struct MtlCompiledShader {
    id<MTLLibrary> library  = nil;
    id<MTLFunction> function = nil;
    std::string mslSource;
    uint64_t shaderHash         = 0; /* Content/variant FNV-1a hash (stable PSO key across reloads) */
    uint32_t usedCbvMask        = 0; /* bit N = CBV regIndex N used */
    uint32_t usedSamplerMask    = 0; /* bit N = sampler N used */
    uint16_t constFloatVecCount = 0; /* Tight float4 register count for CBV 0 */
    MtlSamplerTexKind samplerKind[16] = {};
    bool writesDepth = false;
    bool usesDiscard = false;
    uint8_t colorOutputMask = 0;
};

class MtlParsedShader {
public:
    MtlParsedShader();
    ~MtlParsedShader();

    bool isVertex = false;
    uint64_t bytecodeHash = 0;
    std::vector<uint32_t> rawBytecode;
    std::vector<uint8_t>  serializedIr; /* Legalized dxbc-spirv IR for fast variant specialization */

    /* VS/PS reflection */
    std::vector<MtlVertexInputSemantic> vsInputs;
    uint64_t vsOutputIoHash = 0;
    uint16_t psDeclaredSamplerMask = 0;
    MtlSamplerTexKind psDeclaredSamplerKind[16] = {};
    bool psUsesDiscard = false;
    bool psHasTexkill = false;
    bool psWritesDepth = false;
    bool vsClipSpacePos = false;

    /* Default compiled shader (VS always uses this; PS uses variants map) */
    MtlCompiledShader defaultCompiled;
    std::unordered_map<MtlShaderVariantKey, MtlCompiledShader, MtlShaderVariantKeyHash> psVariants;

    /* Opaque IoMap storage (heap allocated to keep header clean of dxbc-spirv headers) */
    struct Impl;
    std::unique_ptr<Impl> impl;
};

class MtlShaderCompiler {
public:
    explicit MtlShaderCompiler(id<MTLDevice> device);
    ~MtlShaderCompiler();

    /* Parses & legalizes D3D9 SM1-3 bytecode; compiles VS immediately, prepares PS IR. */
    std::shared_ptr<MtlParsedShader> compileFromBytecode(const uint32_t *tokens, bool isVertex);

    /* Returns a compiled PS matching the bound VS outputs, RT mask, alpha-test, point-sprite & sampler modes. */
    const MtlCompiledShader *getOrCompilePsVariant(
        MtlParsedShader &ps,
        const MtlParsedShader *vs,
        uint8_t activeRtMask,
        bool hasDepthAttach,
        bool flatShade,
        bool alphaTestEnable,
        bool pointSpriteEnable,
        uint16_t samplerDepthCmpMask,
        uint16_t samplerNullMask,
        uint16_t samplerProjMask,
        uint16_t samplerGatherMask);

    /* Helper: compute exact D3D9 bytecode length in uint32 tokens (including END token 0x0000FFFF). */
    static size_t measureBytecodeDwords(const uint32_t *tokens);
    static void   setStallHook(void (*fn)(int));

private:
    bool lowerAndCompileToMetal(
        const std::vector<uint8_t> &serializedIr,
        bool isVertex,
        uint64_t cacheKeyHash,
        const MtlParsedShader *vsForIoMatch,
        uint8_t activeRtMask,
        bool hasDepthAttach,
        bool flatShade,
        bool alphaTestEnable,
        bool pointSpriteEnable,
        uint16_t samplerDepthCmpMask,
        uint16_t samplerNullMask,
        uint16_t samplerProjMask,
        uint16_t samplerGatherMask,
        MtlCompiledShader &out);

    id<MTLDevice> device_;
    std::string cacheDir_;

    std::mutex parsedCacheMu_;
    std::unordered_map<uint64_t, std::shared_ptr<MtlParsedShader>> parsedCache_;

    std::mutex libCacheMu_;
    std::unordered_map<uint64_t, MtlCompiledShader> prewarmedLibs_;
    std::atomic<bool> stopPrewarm_{false};
    std::thread prewarmThread_;
};

} // namespace mtl_d3d9
