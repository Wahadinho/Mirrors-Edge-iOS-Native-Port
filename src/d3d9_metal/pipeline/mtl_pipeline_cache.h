#pragma once

#import <Metal/Metal.h>
#include "d3d9_metal_enums.h"
#include "mtl_format.h"
#include "mtl_resources.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <dispatch/dispatch.h>
#include <mutex>
#include <string>
#include <unordered_map>

namespace mtl_d3d9 {

struct MtlRenderPipelineKey {
    uint64_t vsHash = 0;
    uint64_t psHash = 0;
    uint64_t declHash = 0;
    uint64_t streamLayoutHash = 0;
    uint16_t colorFormats[4] = {};
    uint16_t depthFormat = 0;
    uint16_t stencilFormat = 0;
    uint8_t  colorWriteMasks[4] = {};
    uint8_t  colorHasAlphaMask = 0;
    uint8_t  sampleCount = 1;
    uint8_t  blendEnable = 0;
    uint8_t  sepAlphaEnable = 0;
    uint8_t  alphaToCoverage = 0;
    uint8_t  srcBlend = 2;
    uint8_t  dstBlend = 1;
    uint8_t  blendOp = 1;
    uint8_t  srcBlendAlpha = 2;
    uint8_t  dstBlendAlpha = 1;
    uint8_t  blendOpAlpha = 1;
    uint8_t  pad_[5] = {};

    bool operator==(const MtlRenderPipelineKey &o) const {
        return std::memcmp(this, &o, sizeof(*this)) == 0;
    }
};
static_assert(sizeof(MtlRenderPipelineKey) == 64, "MtlRenderPipelineKey packed size");

struct MtlRenderPipelineKeyHash {
    size_t operator()(const MtlRenderPipelineKey &k) const {
        const uint8_t *p = reinterpret_cast<const uint8_t *>(&k);
        size_t h = 14695981039346656037ull;
        for (size_t i = 0; i < sizeof(k); i++) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
        return h;
    }
};

struct MtlDepthStencilKey {
    uint8_t zEnable = 0;
    uint8_t zWrite = 0;
    uint8_t zFunc = 4;
    uint8_t stencilEnable = 0;
    uint8_t twoSided = 0;
    uint8_t frontFunc = 8;
    uint8_t frontFail = 1;
    uint8_t frontZFail = 1;
    uint8_t frontPass = 1;
    uint8_t backFunc = 8;
    uint8_t backFail = 1;
    uint8_t backZFail = 1;
    uint8_t backPass = 1;
    uint8_t readMask = 0xFF;
    uint8_t writeMask = 0xFF;
    uint8_t hasDepth = 0;
    uint8_t hasStencil = 0;

    bool operator==(const MtlDepthStencilKey &o) const {
        return std::memcmp(this, &o, sizeof(*this)) == 0;
    }
};

struct MtlDepthStencilKeyHash {
    size_t operator()(const MtlDepthStencilKey &k) const {
        const uint8_t *p = reinterpret_cast<const uint8_t *>(&k);
        size_t h = 14695981039346656037ull;
        for (size_t i = 0; i < sizeof(k); i++) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
        return h;
    }
};

struct MtlSamplerKey {
    uint8_t addrU = 1;
    uint8_t addrV = 1;
    uint8_t addrW = 1;
    uint8_t magFilter = 1;
    uint8_t minFilter = 1;
    uint8_t mipFilter = 0;
    uint8_t maxAniso = 1;
    uint8_t maxMipLevel = 0;
    uint8_t depthCompare = 0;
    uint8_t pad_[3] = {};
    uint32_t borderColor = 0;

    bool operator==(const MtlSamplerKey &o) const {
        return std::memcmp(this, &o, sizeof(*this)) == 0;
    }
};

struct MtlSamplerKeyHash {
    size_t operator()(const MtlSamplerKey &k) const {
        const uint8_t *p = reinterpret_cast<const uint8_t *>(&k);
        size_t h = 14695981039346656037ull;
        for (size_t i = 0; i < sizeof(k); i++) {
            h ^= p[i];
            h *= 1099511628211ull;
        }
        return h;
    }
};

struct MtlStreamBindingInfo {
    uint32_t stride = 0;
    uint32_t freqSetting = 1;
    bool     bound = false;
};

class MtlPipelineCache {
public:
    explicit MtlPipelineCache(id<MTLDevice> device);
    ~MtlPipelineCache();

    id<MTLRenderPipelineState> getOrCreateRenderPipeline(
        const MtlRenderPipelineKey &key,
        const MtlParsedShader &vs,
        const MtlCompiledShader *ps,
        const MtlVertexDeclaration9 *decl,
        const MtlStreamBindingInfo streams[16]);

    id<MTLDepthStencilState> getOrCreateDepthStencilState(const MtlDepthStencilKey &key);
    id<MTLSamplerState>      getOrCreateSamplerState(const MtlSamplerKey &key);

    /* Built-in helper pipelines (Present blit, StretchRect, sub-rect Clear/ColorFill) */
    id<MTLRenderPipelineState> getBlitPipeline(MTLPixelFormat dstFmt);
    id<MTLRenderPipelineState> getClearPipeline(MTLPixelFormat dstFmt, MTLPixelFormat dsFmt);
    void maybeFlushArchive();

    id<MTLTexture>      nullTexture(MtlSamplerTexKind kind) const;
    id<MTLSamplerState> defaultSampler() const { return defaultSampler_; }
    id<MTLSamplerState> linearClampSampler() const { return linearClampSampler_; }
    id<MTLSamplerState> pointClampSampler() const { return pointClampSampler_; }
    id<MTLBuffer>       zeroAttrBuffer() const { return zeroAttrBuffer_; }

private:
    void initFallbacksAndHelpers();

    id<MTLDevice> device_;
    std::unordered_map<MtlRenderPipelineKey, id<MTLRenderPipelineState>, MtlRenderPipelineKeyHash> psoCache_;
    std::unordered_map<MtlDepthStencilKey, id<MTLDepthStencilState>, MtlDepthStencilKeyHash> dsCache_;
    std::unordered_map<MtlSamplerKey, id<MTLSamplerState>, MtlSamplerKeyHash> sampCache_;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> blitPsoCache_;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> clearPsoCache_;

    id<MTLTexture> nullTex2D_ = nil;
    id<MTLTexture> nullTexCube_ = nil;
    id<MTLTexture> nullTex3D_ = nil;
    id<MTLSamplerState> defaultSampler_ = nil;
    id<MTLSamplerState> linearClampSampler_ = nil;
    id<MTLSamplerState> pointClampSampler_ = nil;
    id<MTLBuffer> zeroAttrBuffer_ = nil;
    id<MTLLibrary> helperLib_ = nil;
    id<MTLFunction> blitVs_ = nil;
    id<MTLFunction> blitPs_ = nil;
    id<MTLFunction> clearVs_ = nil;
    id<MTLFunction> clearPs_ = nil;

    id<MTLBinaryArchive> binaryArchive_ = nil;
    std::string archivePath_;
    std::mutex archiveMu_;
    dispatch_queue_t archiveFlushQueue_ = nullptr;
    std::atomic<bool> archiveFlushPending_{false};
    std::atomic<uint64_t> lastArchiveAddMs_{0};
    uint32_t archiveAddedCount_ = 0;
    uint32_t archiveFlushedCount_ = 0;
    uint8_t  maxAnisoCap_ = 8;
};

} // namespace mtl_d3d9
