#include "mtl_pipeline_cache.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>

extern "C" void host_stall_hook(int begin) __attribute__((weak));

namespace mtl_d3d9 {

static const char *kHelperShadersMsl = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct BlitParams {
    float4 srcRect; /* u0, v0, uSize, vSize */
    float4 dstRect; /* ndcX0, ndcY0, ndcW, ndcH (top-left origin mapped to NDC) */
};

struct BlitOut {
    float4 pos [[position]];
    float2 uv;
};

vertex BlitOut mtl_blit_vs(uint vid [[vertex_id]], constant BlitParams &p [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };
    float2 c = corners[vid & 3u];
    BlitOut o;
    float x = p.dstRect.x + c.x * p.dstRect.z;
    float y = p.dstRect.y + c.y * p.dstRect.w;
    o.pos = float4(x, y, 0.0, 1.0);
    o.uv  = p.srcRect.xy + c * p.srcRect.zw;
    return o;
}

fragment float4 mtl_blit_ps(BlitOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv);
}

struct ClearParams {
    float4 dstRect; /* ndcX0, ndcY0, ndcW, ndcH */
    float4 color;
    float  depth;
    float  _pad[3];
};

vertex float4 mtl_clear_vs(uint vid [[vertex_id]], constant ClearParams &p [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };
    float2 c = corners[vid & 3u];
    float x = p.dstRect.x + c.x * p.dstRect.z;
    float y = p.dstRect.y + c.y * p.dstRect.w;
    return float4(x, y, p.depth, 1.0);
}

fragment float4 mtl_clear_ps(constant ClearParams &p [[buffer(0)]]) {
    return p.color;
}
)MSL";

MtlPipelineCache::MtlPipelineCache(id<MTLDevice> device) : device_(device) {
    const char *envCache = getenv("ME_PC_SHADER_CACHE");
    std::string dir = (envCache && *envCache) ? envCache : "work/metal_shader_cache";
    mkdir("work", 0755);
    mkdir(dir.c_str(), 0755);
    archivePath_ = dir + "/pipelines_v8.metallib";
    if (const char *ae = getenv("ME_PC_MAX_ANISO")) {
        long v = std::strtol(ae, nullptr, 10);
        if (v >= 1 && v <= 16) maxAnisoCap_ = uint8_t(v);
    }
    archiveFlushQueue_ = dispatch_queue_create("com.runnermetal.archiveflush", DISPATCH_QUEUE_SERIAL);

    MTLBinaryArchiveDescriptor *ad = [[MTLBinaryArchiveDescriptor alloc] init];
    struct stat st = {};
    if (stat(archivePath_.c_str(), &st) == 0 && st.st_size > 0) {
        ad.url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:archivePath_.c_str()]];
    }
    NSError *err = nil;
    binaryArchive_ = [device_ newBinaryArchiveWithDescriptor:ad error:&err];
    if (!binaryArchive_ && ad.url != nil) {
        /* Corrupt or older-OS archive: create a fresh archive */
        ad.url = nil;
        binaryArchive_ = [device_ newBinaryArchiveWithDescriptor:ad error:&err];
    }

    initFallbacksAndHelpers();
}

MtlPipelineCache::~MtlPipelineCache() {
    if (archiveFlushQueue_) {
        dispatch_sync(archiveFlushQueue_, ^{});
        archiveFlushQueue_ = nullptr;
    }
    if (binaryArchive_ && archiveAddedCount_ > archiveFlushedCount_ && !archivePath_.empty()) {
        std::lock_guard<std::mutex> lk(archiveMu_);
        std::string tmpPath = archivePath_ + ".tmp.metallib";
        NSURL *tmpUrl = [NSURL fileURLWithPath:[NSString stringWithUTF8String:tmpPath.c_str()]];
        NSError *err = nil;
        if ([binaryArchive_ serializeToURL:tmpUrl error:&err]) {
            std::rename(tmpPath.c_str(), archivePath_.c_str());
        }
    }
    psoCache_.clear();
    dsCache_.clear();
    sampCache_.clear();
    blitPsoCache_.clear();
    clearPsoCache_.clear();
}

void MtlPipelineCache::initFallbacksAndHelpers() {
    /* 1x1 opaque black fallback textures (D3D9 unbound sampler returns (0,0,0,1)) */
    const uint8_t blackPixel[4] = { 0, 0, 0, 255 };

    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:1 height:1 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        nullTex2D_ = [device_ newTextureWithDescriptor:d];
        [nullTex2D_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:blackPixel bytesPerRow:4];
    }
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                        size:1 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        nullTexCube_ = [device_ newTextureWithDescriptor:d];
        for (NSUInteger face = 0; face < 6; face++) {
            [nullTexCube_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:face
                              withBytes:blackPixel bytesPerRow:4 bytesPerImage:4];
        }
    }
    {
        MTLTextureDescriptor *d = [[MTLTextureDescriptor alloc] init];
        d.textureType = MTLTextureType3D;
        d.pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.width = 1; d.height = 1; d.depth = 1;
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        nullTex3D_ = [device_ newTextureWithDescriptor:d];
        [nullTex3D_ replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:0
                        withBytes:blackPixel bytesPerRow:4 bytesPerImage:4];
    }

    zeroAttrBuffer_ = [device_ newBufferWithLength:64 options:MTLResourceStorageModeShared];
    if (zeroAttrBuffer_) std::memset([zeroAttrBuffer_ contents], 0, 64);

    {
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
        sd.sAddressMode = MTLSamplerAddressModeRepeat;
        sd.tAddressMode = MTLSamplerAddressModeRepeat;
        sd.rAddressMode = MTLSamplerAddressModeRepeat;
        defaultSampler_ = [device_ newSamplerStateWithDescriptor:sd];

        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
        pointClampSampler_ = [device_ newSamplerStateWithDescriptor:sd];

        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        linearClampSampler_ = [device_ newSamplerStateWithDescriptor:sd];
    }

    NSError *err = nil;
    helperLib_ = [device_ newLibraryWithSource:[NSString stringWithUTF8String:kHelperShadersMsl]
                                       options:nil error:&err];
    if (!helperLib_) {
        fprintf(stderr, "RunnerMetal: helper MSL compile failed: %s\n",
                err ? [[err localizedDescription] UTF8String] : "unknown");
        return;
    }
    blitVs_  = [helperLib_ newFunctionWithName:@"mtl_blit_vs"];
    blitPs_  = [helperLib_ newFunctionWithName:@"mtl_blit_ps"];
    clearVs_ = [helperLib_ newFunctionWithName:@"mtl_clear_vs"];
    clearPs_ = [helperLib_ newFunctionWithName:@"mtl_clear_ps"];
}

id<MTLTexture> MtlPipelineCache::nullTexture(MtlSamplerTexKind kind) const {
    switch (kind) {
        case MtlSamplerTexKind::TexCube: return nullTexCube_;
        case MtlSamplerTexKind::Tex3D:   return nullTex3D_;
        default:                         return nullTex2D_;
    }
}

static MTLColorWriteMask mapColorWriteMask(uint8_t d3dMask) {
    MTLColorWriteMask m = MTLColorWriteMaskNone;
    if (d3dMask & 1u) m |= MTLColorWriteMaskRed;
    if (d3dMask & 2u) m |= MTLColorWriteMaskGreen;
    if (d3dMask & 4u) m |= MTLColorWriteMaskBlue;
    if (d3dMask & 8u) m |= MTLColorWriteMaskAlpha;
    return m;
}

id<MTLRenderPipelineState> MtlPipelineCache::getOrCreateRenderPipeline(
    const MtlRenderPipelineKey &key,
    const MtlParsedShader &vs,
    const MtlCompiledShader *ps,
    const MtlVertexDeclaration9 *decl,
    const MtlStreamBindingInfo streams[16]) {

    auto it = psoCache_.find(key);
    if (it != psoCache_.end()) return it->second;

    if (!vs.defaultCompiled.function) return nil;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vs.defaultCompiled.function;
    bool hasColorAttachment = (key.colorFormats[0] | key.colorFormats[1] |
                               key.colorFormats[2] | key.colorFormats[3]) != 0;
    bool skipEmptyPs = ps && !hasColorAttachment && !ps->writesDepth && !ps->usesDiscard;
    desc.fragmentFunction = (ps && ps->function && !skipEmptyPs) ? ps->function : nil;
    desc.rasterSampleCount = std::max<uint8_t>(key.sampleCount, 1);
    desc.alphaToCoverageEnabled = (key.alphaToCoverage != 0);

    /* Vertex descriptor matched by D3D9 (Usage, UsageIndex) semantic */
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];
    bool usedStream[16] = {};
    bool usedZero = false;

    for (const auto &inSem : vs.vsInputs) {
        const D3DMtlVertexElement *matched = nullptr;
        if (decl) {
            for (const auto &e : decl->elements()) {
                if (e.Usage == inSem.usage && e.UsageIndex == inSem.usageIndex) {
                    matched = &e;
                    break;
                }
            }
        }

        if (matched && matched->Stream < 16 && streams[matched->Stream].bound && streams[matched->Stream].stride > 0) {
            vd.attributes[inSem.location].format      = mapD3dDeclType(matched->Type);
            vd.attributes[inSem.location].offset      = matched->Offset;
            vd.attributes[inSem.location].bufferIndex = matched->Stream;
            usedStream[matched->Stream] = true;
        } else {
            vd.attributes[inSem.location].format      = MTLVertexFormatFloat4;
            vd.attributes[inSem.location].offset      = 0;
            vd.attributes[inSem.location].bufferIndex = kVsBufZeroAttr;
            usedZero = true;
        }
    }

    for (uint32_t s = 0; s < 16; s++) {
        if (!usedStream[s]) continue;
        vd.layouts[s].stride = streams[s].stride;
        if ((streams[s].freqSetting & D3DM_STREAMSOURCE_INSTANCEDATA) != 0) {
            vd.layouts[s].stepFunction = MTLVertexStepFunctionPerInstance;
            vd.layouts[s].stepRate     = std::max(1u, streams[s].freqSetting & 0x3FFFFFFFu);
        } else {
            vd.layouts[s].stepFunction = MTLVertexStepFunctionPerVertex;
            vd.layouts[s].stepRate     = 1;
        }
    }
    if (usedZero) {
        vd.layouts[kVsBufZeroAttr].stride       = 16;
        vd.layouts[kVsBufZeroAttr].stepFunction = MTLVertexStepFunctionConstant;
        vd.layouts[kVsBufZeroAttr].stepRate     = 0;
    }
    desc.vertexDescriptor = vd;

    /* Color attachments 0..3 */
    for (uint32_t i = 0; i < 4; i++) {
        MTLPixelFormat cf = static_cast<MTLPixelFormat>(key.colorFormats[i]);
        desc.colorAttachments[i].pixelFormat = cf;
        if (cf == MTLPixelFormatInvalid) continue;

        desc.colorAttachments[i].writeMask = mapColorWriteMask(key.colorWriteMasks[i]);

        if (key.blendEnable) {
            bool hasAlpha = (key.colorHasAlphaMask & (1u << i)) != 0;
            uint32_t srcB = key.srcBlend;
            uint32_t dstB = key.dstBlend;
            if (srcB == D3DM_BLEND_BOTHSRCALPHA) {
                srcB = D3DM_BLEND_SRCALPHA;
                dstB = D3DM_BLEND_INVSRCALPHA;
            } else if (srcB == D3DM_BLEND_BOTHINVSRCALPHA) {
                srcB = D3DM_BLEND_INVSRCALPHA;
                dstB = D3DM_BLEND_SRCALPHA;
            }

            MTLBlendFactor srcRgb = mapD3dBlendFactor(srcB, hasAlpha);
            MTLBlendFactor dstRgb = mapD3dBlendFactor(dstB, hasAlpha);
            MTLBlendOperation opRgb = mapD3dBlendOp(key.blendOp);

            MTLBlendFactor srcA = key.sepAlphaEnable ? mapD3dBlendFactor(key.srcBlendAlpha, hasAlpha) : srcRgb;
            MTLBlendFactor dstA = key.sepAlphaEnable ? mapD3dBlendFactor(key.dstBlendAlpha, hasAlpha) : dstRgb;
            MTLBlendOperation opA = key.sepAlphaEnable ? mapD3dBlendOp(key.blendOpAlpha) : opRgb;

            desc.colorAttachments[i].blendingEnabled             = YES;
            desc.colorAttachments[i].sourceRGBBlendFactor        = srcRgb;
            desc.colorAttachments[i].destinationRGBBlendFactor   = dstRgb;
            desc.colorAttachments[i].rgbBlendOperation           = opRgb;
            desc.colorAttachments[i].sourceAlphaBlendFactor      = srcA;
            desc.colorAttachments[i].destinationAlphaBlendFactor = dstA;
            desc.colorAttachments[i].alphaBlendOperation         = opA;
        }
    }

    static bool logStalls = (getenv("ME_PC_LOG_STALLS") && *getenv("ME_PC_LOG_STALLS") == '1');
    auto t0 = logStalls ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    double lockMs = 0.0, psoMs = 0.0;

    desc.depthAttachmentPixelFormat   = static_cast<MTLPixelFormat>(key.depthFormat);
    desc.stencilAttachmentPixelFormat = static_cast<MTLPixelFormat>(key.stencilFormat);
    id<MTLRenderPipelineState> pso = nil;
    NSError *err = nil;
    if (binaryArchive_) {
        std::unique_lock<std::mutex> alk(archiveMu_, std::try_to_lock);
        if (alk.owns_lock()) {
            if (logStalls) {
                lockMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            }
            desc.binaryArchives = @[binaryArchive_];
            pso = [device_ newRenderPipelineStateWithDescriptor:desc
                                                        options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                     reflection:nil
                                                          error:nil];
            if (!pso) {
                struct PsoStallGuard {
                    bool armed = (host_stall_hook != nullptr);
                    PsoStallGuard() { if (armed) host_stall_hook(1); }
                    ~PsoStallGuard() { if (armed) host_stall_hook(0); }
                } psoStallGuard;
                pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
                if (pso) {
                    NSError *aerr = nil;
                    if ([binaryArchive_ addRenderPipelineFunctionsWithDescriptor:desc error:&aerr]) {
                        archiveAddedCount_++;
                        uint64_t nowMs = uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now().time_since_epoch()).count());
                        lastArchiveAddMs_.store(nowMs, std::memory_order_relaxed);
                    }
                }
            }
            if (logStalls) {
                psoMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() - lockMs;
            }
        } else {
            pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
            if (logStalls) {
                psoMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            }
        }
    } else {
        pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
        if (logStalls) {
            psoMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        }
    }
    if (logStalls && (lockMs + psoMs) > 2.0) {
        fprintf(stderr, "STALL_LOG: getOrCreateRenderPipeline lock=%.2f ms pso=%.2f ms\n", lockMs, psoMs);
    }

    if (!pso) {
        fprintf(stderr, "RunnerMetal: PSO creation failed: %s (color0=%u ds=%u/%u)\n",
                err ? [[err localizedDescription] UTF8String] : "unknown",
                key.colorFormats[0], key.depthFormat, key.stencilFormat);
        return nil;
    }

    psoCache_.emplace(key, pso);
    return pso;
}

void MtlPipelineCache::maybeFlushArchive() {
    if (!binaryArchive_ || !archiveFlushQueue_ || archivePath_.empty()) return;
    uint32_t pending = archiveAddedCount_ - archiveFlushedCount_;
    if (pending == 0u) return;
    if (pending < 256u) {
        uint64_t nowMs = uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
        uint64_t lastMs = lastArchiveAddMs_.load(std::memory_order_relaxed);
        if (nowMs < lastMs + 5000ull) return;
    }
    if (archiveFlushPending_.exchange(true, std::memory_order_acq_rel)) return;

    archiveFlushedCount_ = archiveAddedCount_;
    dispatch_async(archiveFlushQueue_, ^{
        @autoreleasepool {
            std::lock_guard<std::mutex> alk(archiveMu_);
            std::string tmpPath = archivePath_ + ".tmp.metallib";
            NSURL *tmpUrl = [NSURL fileURLWithPath:[NSString stringWithUTF8String:tmpPath.c_str()]];
            NSError *err = nil;
            if ([binaryArchive_ serializeToURL:tmpUrl error:&err]) {
                std::rename(tmpPath.c_str(), archivePath_.c_str());
            }
        }
        archiveFlushPending_.store(false, std::memory_order_release);
    });
}

id<MTLDepthStencilState> MtlPipelineCache::getOrCreateDepthStencilState(const MtlDepthStencilKey &key) {
    auto it = dsCache_.find(key);
    if (it != dsCache_.end()) return it->second;

    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
    if (key.hasDepth && key.zEnable != 0) {
        desc.depthCompareFunction = mapD3dCmpFunc(key.zFunc);
        desc.depthWriteEnabled    = (key.zWrite != 0);
    } else {
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        desc.depthWriteEnabled    = NO;
    }

    if (key.hasStencil && key.stencilEnable != 0) {
        MTLStencilDescriptor *front = [[MTLStencilDescriptor alloc] init];
        front.stencilCompareFunction    = mapD3dCmpFunc(key.frontFunc);
        front.stencilFailureOperation   = mapD3dStencilOp(key.frontFail);
        front.depthFailureOperation     = mapD3dStencilOp(key.frontZFail);
        front.depthStencilPassOperation = mapD3dStencilOp(key.frontPass);
        front.readMask                  = key.readMask;
        front.writeMask                 = key.writeMask;
        desc.frontFaceStencil = front;

        if (key.twoSided) {
            MTLStencilDescriptor *back = [[MTLStencilDescriptor alloc] init];
            back.stencilCompareFunction    = mapD3dCmpFunc(key.backFunc);
            back.stencilFailureOperation   = mapD3dStencilOp(key.backFail);
            back.depthFailureOperation     = mapD3dStencilOp(key.backZFail);
            back.depthStencilPassOperation = mapD3dStencilOp(key.backPass);
            back.readMask                  = key.readMask;
            back.writeMask                 = key.writeMask;
            desc.backFaceStencil = back;
        } else {
            desc.backFaceStencil = front;
        }
    }

    id<MTLDepthStencilState> state = [device_ newDepthStencilStateWithDescriptor:desc];
    dsCache_.emplace(key, state);
    return state;
}

id<MTLSamplerState> MtlPipelineCache::getOrCreateSamplerState(const MtlSamplerKey &key) {
    auto it = sampCache_.find(key);
    if (it != sampCache_.end()) return it->second;

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.sAddressMode = mapD3dAddressMode(key.addrU);
    sd.tAddressMode = mapD3dAddressMode(key.addrV);
    sd.rAddressMode = mapD3dAddressMode(key.addrW);

    sd.minFilter = (key.minFilter == D3DM_TEXF_LINEAR || key.minFilter == D3DM_TEXF_ANISOTROPIC)
        ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    sd.magFilter = (key.magFilter == D3DM_TEXF_LINEAR || key.magFilter == D3DM_TEXF_ANISOTROPIC)
        ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;

    switch (key.mipFilter) {
        case D3DM_TEXF_POINT:       sd.mipFilter = MTLSamplerMipFilterNearest; break;
        case D3DM_TEXF_LINEAR:
        case D3DM_TEXF_ANISOTROPIC: sd.mipFilter = MTLSamplerMipFilterLinear;  break;
        default:                    sd.mipFilter = MTLSamplerMipFilterNotMipmapped; break;
    }

    if (key.minFilter == D3DM_TEXF_ANISOTROPIC || key.magFilter == D3DM_TEXF_ANISOTROPIC) {
        sd.maxAnisotropy = std::clamp<NSUInteger>(key.maxAniso, 1, maxAnisoCap_);
    } else {
        sd.maxAnisotropy = 1;
    }

    sd.lodMinClamp = float(key.maxMipLevel);
    if (key.depthCompare) {
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.maxAnisotropy = 1;
        sd.compareFunction = MTLCompareFunctionLessEqual;
    } else {
        sd.compareFunction = MTLCompareFunctionNever;
    }

    uint8_t a = uint8_t((key.borderColor >> 24) & 0xFFu);
    uint8_t r = uint8_t((key.borderColor >> 16) & 0xFFu);
    uint8_t g = uint8_t((key.borderColor >>  8) & 0xFFu);
    uint8_t b = uint8_t((key.borderColor >>  0) & 0xFFu);
    if (a < 128) {
        sd.borderColor = MTLSamplerBorderColorTransparentBlack;
    } else if (uint32_t(r) + g + b > 384u) {
        sd.borderColor = MTLSamplerBorderColorOpaqueWhite;
    } else {
        sd.borderColor = MTLSamplerBorderColorOpaqueBlack;
    }

    id<MTLSamplerState> smp = [device_ newSamplerStateWithDescriptor:sd];
    sampCache_.emplace(key, smp);
    return smp;
}

id<MTLRenderPipelineState> MtlPipelineCache::getBlitPipeline(MTLPixelFormat dstFmt) {
    uint32_t k = uint32_t(dstFmt);
    auto it = blitPsoCache_.find(k);
    if (it != blitPsoCache_.end()) return it->second;

    if (!blitVs_ || !blitPs_) return nil;
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = blitVs_;
    desc.fragmentFunction = blitPs_;
    desc.colorAttachments[0].pixelFormat = dstFmt;
    NSError *err = nil;
    id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pso) {
        fprintf(stderr, "RunnerMetal: blit PSO failed for fmt %lu: %s\n",
                (unsigned long)dstFmt, err ? [[err localizedDescription] UTF8String] : "unknown");
        return nil;
    }
    blitPsoCache_.emplace(k, pso);
    return pso;
}

id<MTLRenderPipelineState> MtlPipelineCache::getClearPipeline(MTLPixelFormat dstFmt, MTLPixelFormat dsFmt) {
    uint64_t k = (uint64_t(dstFmt) << 32) | uint64_t(dsFmt);
    auto it = clearPsoCache_.find(k);
    if (it != clearPsoCache_.end()) return it->second;

    if (!clearVs_ || !clearPs_) return nil;
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = clearVs_;
    desc.fragmentFunction = (dstFmt != MTLPixelFormatInvalid) ? clearPs_ : nil;
    desc.colorAttachments[0].pixelFormat = dstFmt;
    desc.depthAttachmentPixelFormat = dsFmt;
    desc.stencilAttachmentPixelFormat =
        (dsFmt == MTLPixelFormatDepth32Float_Stencil8) ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    NSError *err = nil;
    id<MTLRenderPipelineState> pso = [device_ newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!pso) {
        fprintf(stderr, "RunnerMetal: clear PSO failed for fmt %lu/%lu: %s\n",
                (unsigned long)dstFmt, (unsigned long)dsFmt,
                err ? [[err localizedDescription] UTF8String] : "unknown");
        return nil;
    }
    clearPsoCache_.emplace(k, pso);
    return pso;
}

} // namespace mtl_d3d9
