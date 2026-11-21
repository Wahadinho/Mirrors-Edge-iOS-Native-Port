#include "mtl_resources.h"
#include "mtl_d3d9_device.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace mtl_d3d9 {

static uint32_t calcMipLevels(uint32_t w, uint32_t h, uint32_t d, uint32_t requested) {
    uint32_t m = std::max({w, h, d, 1u});
    uint32_t maxLevels = 1;
    while (m > 1) {
        m >>= 1;
        maxLevels++;
    }
    if (requested == 0 || requested > maxLevels) return maxLevels;
    return requested;
}

static uint64_t fnv1a64Bytes(const void *data, size_t n) {
    const uint8_t *p = static_cast<const uint8_t *>(data);
    uint64_t h = 14695981039346656037ull;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

static inline bool isBCPixelFormat(MTLPixelFormat fmt) {
    return fmt == MTLPixelFormatBC1_RGBA || fmt == MTLPixelFormatBC1_RGBA_sRGB ||
           fmt == MTLPixelFormatBC2_RGBA || fmt == MTLPixelFormatBC2_RGBA_sRGB ||
           fmt == MTLPixelFormatBC3_RGBA || fmt == MTLPixelFormatBC3_RGBA_sRGB ||
           fmt == MTLPixelFormatBC4_RUnorm || fmt == MTLPixelFormatBC5_RGUnorm;
}

static inline void unpackRGB565(uint16_t c, uint8_t &r, uint8_t &g, uint8_t &b) {
    r = uint8_t(((c >> 11) & 0x1F) * 255 / 31);
    g = uint8_t(((c >> 5) & 0x3F) * 255 / 63);
    b = uint8_t((c & 0x1F) * 255 / 31);
}

static void decodeBC1Block(const uint8_t *blk, uint8_t *out, uint32_t stride, bool punchthroughAlpha) {
    uint16_t c0 = uint16_t(blk[0]) | (uint16_t(blk[1]) << 8);
    uint16_t c1 = uint16_t(blk[2]) | (uint16_t(blk[3]) << 8);
    uint8_t col[4][4];
    unpackRGB565(c0, col[0][0], col[0][1], col[0][2]); col[0][3] = 255;
    unpackRGB565(c1, col[1][0], col[1][1], col[1][2]); col[1][3] = 255;
    if (!punchthroughAlpha || c0 > c1) {
        for (int i = 0; i < 3; i++) {
            col[2][i] = uint8_t((2 * col[0][i] + col[1][i]) / 3);
            col[3][i] = uint8_t((col[0][i] + 2 * col[1][i]) / 3);
        }
        col[2][3] = 255; col[3][3] = 255;
    } else {
        for (int i = 0; i < 3; i++) {
            col[2][i] = uint8_t((col[0][i] + col[1][i]) / 2);
            col[3][i] = 0;
        }
        col[2][3] = 255; col[3][3] = 0;
    }
    uint32_t bits = uint32_t(blk[4]) | (uint32_t(blk[5]) << 8) | (uint32_t(blk[6]) << 16) | (uint32_t(blk[7]) << 24);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            uint8_t idx = (bits >> (2 * (y * 4 + x))) & 3;
            uint8_t *p = out + y * stride + x * 4;
            p[0] = col[idx][0]; p[1] = col[idx][1]; p[2] = col[idx][2]; p[3] = col[idx][3];
        }
    }
}

static void decodeAlpha4Bit(const uint8_t *blk, uint8_t *out, uint32_t stride) {
    for (int y = 0; y < 4; y++) {
        uint16_t row = uint16_t(blk[y * 2]) | (uint16_t(blk[y * 2 + 1]) << 8);
        for (int x = 0; x < 4; x++) {
            uint8_t a = (row >> (4 * x)) & 0xF;
            out[y * stride + x * 4 + 3] = (a << 4) | a;
        }
    }
}

static void decodeAlpha8Bit(const uint8_t *blk, uint8_t *out, uint32_t stride, int channelOffset) {
    uint8_t a[8];
    a[0] = blk[0]; a[1] = blk[1];
    if (a[0] > a[1]) {
        for (int i = 1; i <= 6; i++) a[i + 1] = uint8_t(((7 - i) * a[0] + i * a[1]) / 7);
    } else {
        for (int i = 1; i <= 4; i++) a[i + 1] = uint8_t(((5 - i) * a[0] + i * a[1]) / 5);
        a[6] = 0; a[7] = 255;
    }
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= uint64_t(blk[2 + i]) << (8 * i);
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            uint8_t idx = (bits >> (3 * (y * 4 + x))) & 7;
            out[y * stride + x * 4 + channelOffset] = a[idx];
        }
    }
}

static void decompressBCToRGBA8(MTLPixelFormat fmt, const uint8_t *src, uint32_t srcPitch, uint8_t *dst, uint32_t dstPitch, uint32_t w, uint32_t h) {
    uint32_t bxCount = (w + 3) / 4;
    uint32_t byCount = (h + 3) / 4;
    uint32_t blkBytes = (fmt == MTLPixelFormatBC1_RGBA || fmt == MTLPixelFormatBC1_RGBA_sRGB || fmt == MTLPixelFormatBC4_RUnorm) ? 8 : 16;
    uint8_t tmp[16 * 4];
    for (uint32_t by = 0; by < byCount; by++) {
        const uint8_t *rowSrc = src + size_t(by) * srcPitch;
        for (uint32_t bx = 0; bx < bxCount; bx++) {
            const uint8_t *b = rowSrc + size_t(bx) * blkBytes;
            std::memset(tmp, 0, sizeof(tmp));
            if (fmt == MTLPixelFormatBC1_RGBA || fmt == MTLPixelFormatBC1_RGBA_sRGB) {
                decodeBC1Block(b, tmp, 16, true);
            } else if (fmt == MTLPixelFormatBC2_RGBA || fmt == MTLPixelFormatBC2_RGBA_sRGB) {
                decodeBC1Block(b + 8, tmp, 16, false);
                decodeAlpha4Bit(b, tmp, 16);
            } else if (fmt == MTLPixelFormatBC3_RGBA || fmt == MTLPixelFormatBC3_RGBA_sRGB) {
                decodeBC1Block(b + 8, tmp, 16, false);
                decodeAlpha8Bit(b, tmp, 16, 3);
            } else if (fmt == MTLPixelFormatBC4_RUnorm) {
                decodeAlpha8Bit(b, tmp, 16, 0);
                for (int p = 0; p < 16; p++) { tmp[p*4+1] = tmp[p*4]; tmp[p*4+2] = tmp[p*4]; tmp[p*4+3] = 255; }
            } else if (fmt == MTLPixelFormatBC5_RGUnorm) {
                decodeAlpha8Bit(b, tmp, 16, 1);     // ATI2 block 0 -> G
                decodeAlpha8Bit(b + 8, tmp, 16, 0); // ATI2 block 1 -> R
                for (int p = 0; p < 16; p++) { tmp[p*4+2] = 0; tmp[p*4+3] = 255; }
            }
            for (uint32_t py = 0; py < 4 && (by * 4 + py) < h; py++) {
                for (uint32_t px = 0; px < 4 && (bx * 4 + px) < w; px++) {
                    std::memcpy(dst + size_t(by * 4 + py) * dstPitch + size_t(bx * 4 + px) * 4, tmp + py * 16 + px * 4, 4);
                }
            }
        }
    }
}

static id<MTLTexture> createMetalTexture(MtlDirect3DDevice9 *dev, MTLTextureType type,
                                         const MtlFormatInfo &fi,
                                         uint32_t w, uint32_t h, uint32_t d,
                                         uint32_t levels, uint32_t usage) {
    if (fi.isNullFormat || fi.pixelFormat == MTLPixelFormatInvalid) return nil;

    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = type;
    MTLPixelFormat actualFmt = fi.pixelFormat;
    bool bcFallback = isBCPixelFormat(actualFmt) && ![dev->mtlDevice() supportsBCTextureCompression];
    if (bcFallback) actualFmt = MTLPixelFormatRGBA8Unorm;
    desc.pixelFormat = actualFmt;
    desc.width = std::max(w, 1u);
    desc.height = std::max(h, 1u);
    desc.depth = (type == MTLTextureType3D) ? std::max(d, 1u) : 1u;
    desc.mipmapLevelCount = std::max(levels, 1u);
    desc.sampleCount = 1;
    desc.arrayLength = 1;
    desc.storageMode = MTLStorageModePrivate;

    MTLTextureUsage mtlUsage = MTLTextureUsageShaderRead;
    if ((usage & D3DM_USAGE_RENDERTARGET) || (usage & D3DM_USAGE_DEPTHSTENCIL) || fi.isDepth) {
        mtlUsage |= MTLTextureUsageRenderTarget;
    }
    /* Apple GPUs allow sRGB and swizzle views without PixelFormatView, preserving lossless compression */
    if ((fi.srgbPixelFormat != MTLPixelFormatInvalid || fi.hasSwizzle) && !dev->isAppleGpu()) {
        mtlUsage |= MTLTextureUsagePixelFormatView;
    }
    desc.usage = mtlUsage;

    id<MTLTexture> tex = [dev->mtlDevice() newTextureWithDescriptor:desc];
    if (!tex) {
        fprintf(stderr, "RunnerMetal: newTextureWithDescriptor failed (%ux%ux%u levels=%u fmt=%lu)\n",
                w, h, d, levels, (unsigned long)fi.pixelFormat);
    }
    return tex;
}

/* ========================================================================= */
/* MtlRingBuffer                                                             */
/* ========================================================================= */

MtlRingBuffer::MtlRingBuffer(id<MTLDevice> device) : device_(device) {
    for (uint32_t i = 0; i < kFrameSlots; i++) {
        slots_[i] = [device_ newBufferWithLength:kSlotSize options:MTLResourceStorageModeShared];
        slotPtrs_[i] = slots_[i] ? [slots_[i] contents] : nullptr;
        offsets_[i] = 0;
    }
}

MtlRingBuffer::~MtlRingBuffer() {
    for (uint32_t i = 0; i < kFrameSlots; i++) {
        overflow_[i].clear();
        slots_[i] = nil;
        slotPtrs_[i] = nullptr;
    }
}

void MtlRingBuffer::beginFrame(uint32_t frameIndex) {
    std::lock_guard<std::mutex> lk(mu_);
    curSlot_ = frameIndex % kFrameSlots;
    offsets_[curSlot_] = 0;
    overflow_[curSlot_].clear();
}

MtlRingBuffer::Allocation MtlRingBuffer::alloc(size_t size, size_t alignment) {
    std::lock_guard<std::mutex> lk(mu_);
    if (size == 0) size = 16;
    if (alignment < 16) alignment = 16;

    size_t aligned = (offsets_[curSlot_] + (alignment - 1)) & ~(alignment - 1);
    if (slots_[curSlot_] && aligned + size <= kSlotSize) {
        offsets_[curSlot_] = aligned + size;
        return { slots_[curSlot_], aligned, static_cast<uint8_t *>(slotPtrs_[curSlot_]) + aligned };
    }

    size_t bufSize = (size + 4095u) & ~size_t(4095u);
    id<MTLBuffer> extra = [device_ newBufferWithLength:bufSize options:MTLResourceStorageModeShared];
    overflow_[curSlot_].push_back(extra);
    return { extra, 0, extra ? [extra contents] : nullptr };
}

/* Shared GPU-sequence-tracked buffer renaming helper for dynamic/in-flight VB & IB locks */
static MTL_HRESULT lockSharedBufferWithRename(
    MtlDirect3DDevice9 *device, uint32_t usage, uint32_t byteLength,
    __strong id<MTLBuffer> &activeBuffer, size_t &activeOffset,
    uint64_t lastUsedSeq, const std::shared_ptr<MtlSharedBufferPool> &bufPool,
    std::vector<MtlBufferDynSlot> &dynSlots, int32_t &activeDynSlot,
    uint32_t offset, void **ppbData, uint32_t flags) {
    if (!ppbData || offset > byteLength) return D3D_ERR_INVALIDCALL;

    const bool readOnly    = (flags & D3DM_LOCK_READONLY) != 0;
    const bool noOverwrite = (flags & D3DM_LOCK_NOOVERWRITE) != 0;
    const bool discard     = (flags & D3DM_LOCK_DISCARD) != 0;
    const bool isDynamic   = (usage & D3DM_USAGE_DYNAMIC) != 0;

    if (!readOnly && !noOverwrite) {
        uint64_t doneSeq = device->completedCommandSeq();
        bool inFlight = (lastUsedSeq > doneSeq);
        if ((isDynamic && discard && offset == 0) || inFlight) {
            uint64_t curSeq = device->currentCommandSeq();
            int32_t chosen = -1;
            for (size_t i = 0; i < dynSlots.size(); i++) {
                if (int32_t(i) != activeDynSlot && dynSlots[i].lastSeq <= doneSeq) {
                    chosen = int32_t(i);
                    break;
                }
            }
            if (chosen < 0) {
                size_t allocSize = std::max<size_t>(byteLength, 16u);
                id<MTLBuffer> buf = bufPool
                    ? bufPool->acquire(allocSize)
                    : [device->mtlDevice() newBufferWithLength:allocSize options:MTLResourceStorageModeShared];
                if (!buf) return D3D_E_OUTOFMEMORY;
                chosen = int32_t(dynSlots.size());
                dynSlots.push_back({ buf, curSeq });
            } else {
                dynSlots[chosen].lastSeq = curSeq;
            }
            id<MTLBuffer> oldBuf = activeBuffer;
            size_t oldOff = activeOffset;
            activeDynSlot = chosen;
            activeBuffer  = dynSlots[chosen].buffer;
            activeOffset  = 0;
            if ((!discard || offset > 0) && oldBuf != nil && byteLength > 0) {
                std::memcpy([activeBuffer contents],
                            static_cast<const uint8_t *>([oldBuf contents]) + oldOff,
                            byteLength);
            }
        }
    }

    if (!activeBuffer) return D3D_E_OUTOFMEMORY;
    *ppbData = static_cast<uint8_t *>([activeBuffer contents]) + activeOffset + offset;
    return D3D_S_OK;
}

/* ========================================================================= */
/* MtlVertexBuffer9                                                          */
/* ========================================================================= */

MtlVertexBuffer9::MtlVertexBuffer9(MtlDirect3DDevice9 *dev, uint32_t length,
                                   uint32_t usage, uint32_t fvf, uint32_t pool)
    : device_(dev), bufPool_(dev->sharedBufferPool()) {
    desc_.Format = D3DM_FMT_VERTEXDATA;
    desc_.Type   = D3DM_RTYPE_VERTEXBUFFER;
    desc_.Usage  = usage;
    desc_.Pool   = pool;
    desc_.Size   = length;
    desc_.FVF    = fvf;

    size_t allocSize = std::max<size_t>(length, 16u);
    baseBuffer_ = bufPool_
        ? bufPool_->acquire(allocSize)
        : [dev->mtlDevice() newBufferWithLength:allocSize options:MTLResourceStorageModeShared];
    if (baseBuffer_ && !(usage & (D3DM_USAGE_DYNAMIC | D3DM_USAGE_WRITEONLY))) {
        std::memset([baseBuffer_ contents], 0, allocSize);
    }
    activeBuffer_ = baseBuffer_;
    activeOffset_ = 0;
}

MtlVertexBuffer9::~MtlVertexBuffer9() {
    if (bufPool_) {
        bufPool_->release(baseBuffer_, lastUsedSeq_);
        for (const auto &s : dynSlots_) {
            bufPool_->release(s.buffer, s.lastSeq);
        }
    }
}

MTL_HRESULT MtlVertexBuffer9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

void MtlVertexBuffer9::markUsed(uint64_t cmdSeq) {
    if (cmdSeq > lastUsedSeq_) lastUsedSeq_ = cmdSeq;
    if (activeDynSlot_ >= 0 && size_t(activeDynSlot_) < dynSlots_.size()) {
        if (cmdSeq > dynSlots_[activeDynSlot_].lastSeq) {
            dynSlots_[activeDynSlot_].lastSeq = cmdSeq;
        }
    }
}

MTL_HRESULT MtlVertexBuffer9::Lock(uint32_t offset, uint32_t size, void **ppbData, uint32_t flags) {
    (void)size;
    return lockSharedBufferWithRename(device_, desc_.Usage, desc_.Size,
                                      activeBuffer_, activeOffset_, lastUsedSeq_, bufPool_,
                                      dynSlots_, activeDynSlot_, offset, ppbData, flags);
}

MTL_HRESULT MtlVertexBuffer9::Unlock() {
    return D3D_S_OK;
}

MTL_HRESULT MtlVertexBuffer9::GetDesc(D3DMtlBufferDesc *pDesc) {
    if (!pDesc) return D3D_ERR_INVALIDCALL;
    *pDesc = desc_;
    return D3D_S_OK;
}

/* ========================================================================= */
/* MtlIndexBuffer9                                                           */
/* ========================================================================= */

MtlIndexBuffer9::MtlIndexBuffer9(MtlDirect3DDevice9 *dev, uint32_t length,
                                 uint32_t usage, uint32_t format, uint32_t pool)
    : device_(dev), bufPool_(dev->sharedBufferPool()) {
    desc_.Format = format;
    desc_.Type   = D3DM_RTYPE_INDEXBUFFER;
    desc_.Usage  = usage;
    desc_.Pool   = pool;
    desc_.Size   = length;
    desc_.FVF    = 0;

    size_t allocSize = std::max<size_t>(length, 16u);
    baseBuffer_ = bufPool_
        ? bufPool_->acquire(allocSize)
        : [dev->mtlDevice() newBufferWithLength:allocSize options:MTLResourceStorageModeShared];
    if (baseBuffer_ && !(usage & (D3DM_USAGE_DYNAMIC | D3DM_USAGE_WRITEONLY))) {
        std::memset([baseBuffer_ contents], 0, allocSize);
    }
    activeBuffer_ = baseBuffer_;
    activeOffset_ = 0;
}

MtlIndexBuffer9::~MtlIndexBuffer9() {
    if (bufPool_) {
        bufPool_->release(baseBuffer_, lastUsedSeq_);
        for (const auto &s : dynSlots_) {
            bufPool_->release(s.buffer, s.lastSeq);
        }
    }
}

MTL_HRESULT MtlIndexBuffer9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

void MtlIndexBuffer9::markUsed(uint64_t cmdSeq) {
    if (cmdSeq > lastUsedSeq_) lastUsedSeq_ = cmdSeq;
    if (activeDynSlot_ >= 0 && size_t(activeDynSlot_) < dynSlots_.size()) {
        if (cmdSeq > dynSlots_[activeDynSlot_].lastSeq) {
            dynSlots_[activeDynSlot_].lastSeq = cmdSeq;
        }
    }
}

MTL_HRESULT MtlIndexBuffer9::Lock(uint32_t offset, uint32_t size, void **ppbData, uint32_t flags) {
    (void)size;
    return lockSharedBufferWithRename(device_, desc_.Usage, desc_.Size,
                                      activeBuffer_, activeOffset_, lastUsedSeq_, bufPool_,
                                      dynSlots_, activeDynSlot_, offset, ppbData, flags);
}

MTL_HRESULT MtlIndexBuffer9::Unlock() {
    return D3D_S_OK;
}

MTL_HRESULT MtlIndexBuffer9::GetDesc(D3DMtlBufferDesc *pDesc) {
    if (!pDesc) return D3D_ERR_INVALIDCALL;
    *pDesc = desc_;
    return D3D_S_OK;
}

/* ========================================================================= */
/* MtlSurface9                                                               */
/* ========================================================================= */

MtlSurface9::MtlSurface9(MtlDirect3DDevice9 *dev, uint32_t w, uint32_t h, uint32_t format,
                         uint32_t usage, uint32_t pool, uint32_t msType, uint32_t msQual,
                         id<MTLTexture> existingTex, IMtlUnknown *container,
                         uint32_t mipLevel, uint32_t slice)
    : device_(dev), container_(container), mipLevel_(mipLevel), slice_(slice) {
    desc_.Format             = format;
    desc_.Type               = D3DM_RTYPE_SURFACE;
    desc_.Usage              = usage;
    desc_.Pool               = pool;
    desc_.MultiSampleType    = msType;
    desc_.MultiSampleQuality = msQual;
    desc_.Width              = std::max(w, 1u);
    desc_.Height             = std::max(h, 1u);
    fmtInfo_ = mapD3dFormat(format);

    if (existingTex != nil) {
        texture_ = existingTex;
    } else if (!fmtInfo_.isNullFormat && !isSysMem() && fmtInfo_.pixelFormat != MTLPixelFormatInvalid) {
        texture_ = createMetalTexture(dev, MTLTextureType2D, fmtInfo_,
                                      desc_.Width, desc_.Height, 1, 1, usage);
    }
}

MtlSurface9::~MtlSurface9() {
    srgbView_ = nil;
    texture_ = nil;
}

uint32_t MtlSurface9::AddRef() {
    if (container_) return container_->AddRef();
    return MtlComObject<MtlSurface9, IMtlDirect3DSurface9>::AddRef();
}

uint32_t MtlSurface9::Release() {
    if (container_) return container_->Release();
    return MtlComObject<MtlSurface9, IMtlDirect3DSurface9>::Release();
}

MTL_HRESULT MtlSurface9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlSurface9::GetContainer(const D3DMtlGuid *riid, void **ppContainer) {
    if (!ppContainer) return D3D_ERR_INVALIDCALL;
    if (!container_) return D3D_E_NOINTERFACE;
    return container_->QueryInterface(riid, ppContainer);
}

MTL_HRESULT MtlSurface9::GetDesc(D3DMtlSurfaceDesc *pDesc) {
    if (!pDesc) return D3D_ERR_INVALIDCALL;
    *pDesc = desc_;
    return D3D_S_OK;
}

id<MTLTexture> MtlSurface9::srgbRenderTargetView() {
    if (!texture_ || fmtInfo_.srgbPixelFormat == MTLPixelFormatInvalid) return texture_;
    if (!srgbView_) {
        /* Never swizzle a render target view */
        srgbView_ = [texture_ newTextureViewWithPixelFormat:fmtInfo_.srgbPixelFormat];
    }
    return srgbView_ ? srgbView_ : texture_;
}

void MtlSurface9::replaceTexture(id<MTLTexture> newTex, uint32_t w, uint32_t h, uint32_t format) {
    srgbView_ = nil;
    texture_ = newTex;
    desc_.Width = std::max(w, 1u);
    desc_.Height = std::max(h, 1u);
    desc_.Format = format;
    fmtInfo_ = mapD3dFormat(format);
    cpuData_.clear();
}

void MtlSurface9::ensureCpuBacking() {
    uint32_t rowPitch = calcRowPitch(desc_.Format, desc_.Width);
    size_t needed = size_t(calcSliceSize(desc_.Format, desc_.Width, desc_.Height)) + rowPitch;
    if (cpuData_.size() < needed) {
        cpuData_.resize(needed, 0);
    }
}

MTL_HRESULT MtlSurface9::LockRect(D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) {
    if (!pLockedRect) return D3D_ERR_INVALIDCALL;
    if (fmtInfo_.isNullFormat) return D3D_ERR_INVALIDCALL;

    uint32_t rowPitch = calcRowPitch(desc_.Format, desc_.Width);

    /* Fast path: stage full-surface discard/dynamic texture writes directly in MtlRingBuffer (0 extra memcpy) */
    if (!isSysMem() && texture_ != nil && !(isBCPixelFormat(fmtInfo_.pixelFormat) && [texture_ pixelFormat] == MTLPixelFormatRGBA8Unorm) && !(desc_.Usage & D3DM_USAGE_RENDERTARGET) &&
        !(Flags & D3DM_LOCK_READONLY) && !pRect && cpuData_.empty() &&
        ((Flags & D3DM_LOCK_DISCARD) || (desc_.Usage & D3DM_USAGE_DYNAMIC))) {
        uint32_t rows = calcRowCount(desc_.Format, desc_.Height);
        size_t uploadBytes = size_t(rowPitch) * rows;
        auto alloc = device_->ringBuffer().alloc(uploadBytes, 16);
        if (alloc.cpuPtr) {
            stagedLockAlloc_ = alloc;
            stagedRowPitch_ = rowPitch;
            stagedBytes_ = uint32_t(uploadBytes);
            hasLockedRect_ = false;
            lockReadOnly_ = false;
            pLockedRect->Pitch = int32_t(rowPitch);
            pLockedRect->pBits = alloc.cpuPtr;
            return D3D_S_OK;
        }
    }

    ensureCpuBacking();

    /* If locking a GPU render target (not discarding and not already backed by recent CPU data), read it back */
    if (!isSysMem() && texture_ != nil && (desc_.Usage & D3DM_USAGE_RENDERTARGET) != 0 &&
        !(Flags & D3DM_LOCK_DISCARD)) {
        device_->readbackTextureToCpu(texture_, mipLevel_, slice_, desc_.Format, desc_.Width, desc_.Height, cpuData_);
    }

    size_t byteOffset = 0;

    if (pRect) {
        uint32_t rx = uint32_t(std::max(pRect->left, 0));
        uint32_t ry = uint32_t(std::max(pRect->top, 0));
        uint32_t bx = rx / std::max(fmtInfo_.blockWidth, 1u);
        uint32_t by = ry / std::max(fmtInfo_.blockHeight, 1u);
        byteOffset = size_t(by) * rowPitch + size_t(bx) * std::max(fmtInfo_.blockBytes, 1u);
        lockedRect_ = *pRect;
        hasLockedRect_ = true;
    } else {
        hasLockedRect_ = false;
    }

    lockReadOnly_ = (Flags & D3DM_LOCK_READONLY) != 0;
    pLockedRect->Pitch = int32_t(rowPitch);
    pLockedRect->pBits = cpuData_.data() + byteOffset;
    return D3D_S_OK;
}

void MtlSurface9::uploadCpuToGpu(const D3DMtlRect *rect) {
    if (isSysMem() || texture_ == nil || cpuData_.empty() || fmtInfo_.isNullFormat) return;

    uint32_t bw = std::max(fmtInfo_.blockWidth, 1u);
    uint32_t bh = std::max(fmtInfo_.blockHeight, 1u);
    uint32_t bb = std::max(fmtInfo_.blockBytes, 1u);

    uint32_t rx = 0, ry = 0, rw = desc_.Width, rh = desc_.Height;
    if (rect) {
        rx = uint32_t(std::clamp<int32_t>(rect->left, 0, int32_t(desc_.Width)));
        ry = uint32_t(std::clamp<int32_t>(rect->top, 0, int32_t(desc_.Height)));
        uint32_t rRight = uint32_t(std::clamp<int32_t>(rect->right, int32_t(rx), int32_t(desc_.Width)));
        uint32_t rBottom = uint32_t(std::clamp<int32_t>(rect->bottom, int32_t(ry), int32_t(desc_.Height)));
        /* Align to BC block boundary */
        rx = (rx / bw) * bw;
        ry = (ry / bh) * bh;
        rRight = std::min(desc_.Width, ((rRight + bw - 1u) / bw) * bw);
        rBottom = std::min(desc_.Height, ((rBottom + bh - 1u) / bh) * bh);
        rw = (rRight > rx) ? (rRight - rx) : 0;
        rh = (rBottom > ry) ? (rBottom - ry) : 0;
    }
    if (rw == 0 || rh == 0) return;

    uint32_t fullRowPitch = calcRowPitch(desc_.Format, desc_.Width);
    uint32_t startBlockX  = rx / bw;
    uint32_t startBlockY  = ry / bh;

    if (isBCPixelFormat(fmtInfo_.pixelFormat) && [texture_ pixelFormat] == MTLPixelFormatRGBA8Unorm) {
        uint32_t rgbaPitch = rw * 4u;
        size_t rgbaBytes = size_t(rgbaPitch) * rh;
        auto alloc = device_->ringBuffer().alloc(rgbaBytes, 16);
        if (!alloc.cpuPtr) return;
        const uint8_t *srcBase = cpuData_.data() + size_t(startBlockY) * fullRowPitch + size_t(startBlockX) * bb;
        decompressBCToRGBA8(fmtInfo_.pixelFormat, srcBase, fullRowPitch, static_cast<uint8_t *>(alloc.cpuPtr), rgbaPitch, rw, rh);
        PendingTextureUpload up = {};
        up.srcBuffer = alloc.buffer; up.srcOffset = alloc.offset;
        up.srcBytesPerRow = rgbaPitch; up.srcBytesPerImage = uint32_t(rgbaBytes);
        up.dstTexture = texture_; up.dstSlice = slice_; up.dstLevel = mipLevel_;
        up.dstOrigin = MTLOriginMake(rx, ry, 0); up.dstSize = MTLSizeMake(rw, rh, 1);
        device_->enqueueTextureUpload(up);
        return;
    }

    uint32_t uploadRowPitch = calcRowPitch(desc_.Format, rw);
    uint32_t uploadRows     = calcRowCount(desc_.Format, rh);
    size_t   uploadBytes    = size_t(uploadRowPitch) * uploadRows;

    auto alloc = device_->ringBuffer().alloc(uploadBytes, 16);
    if (!alloc.cpuPtr) return;

    uint8_t *dst = static_cast<uint8_t *>(alloc.cpuPtr);

    if (rx == 0 && uploadRowPitch == fullRowPitch) {
        std::memcpy(dst, cpuData_.data() + size_t(startBlockY) * fullRowPitch, uploadBytes);
    } else {
        for (uint32_t row = 0; row < uploadRows; row++) {
            const uint8_t *srcRow = cpuData_.data() + size_t(startBlockY + row) * fullRowPitch + size_t(startBlockX) * bb;
            std::memcpy(dst + size_t(row) * uploadRowPitch, srcRow, uploadRowPitch);
        }
    }

    PendingTextureUpload up = {};
    up.srcBuffer        = alloc.buffer;
    up.srcOffset        = alloc.offset;
    up.srcBytesPerRow   = uploadRowPitch;
    up.srcBytesPerImage = uint32_t(uploadBytes);
    up.dstTexture       = texture_;
    up.dstSlice         = slice_;
    up.dstLevel         = mipLevel_;
    up.dstOrigin        = MTLOriginMake(rx, ry, 0);
    up.dstSize          = MTLSizeMake(rw, rh, 1);
    device_->enqueueTextureUpload(up);

    if ((desc_.Usage & D3DM_USAGE_AUTOGENMIPMAP) != 0 && mipLevel_ == 0 && [texture_ mipmapLevelCount] > 1) {
        device_->enqueueGenerateMipmaps(texture_);
    }
}

MTL_HRESULT MtlSurface9::UnlockRect() {
    if (stagedLockAlloc_.buffer != nil) {
        PendingTextureUpload up = {};
        up.srcBuffer        = stagedLockAlloc_.buffer;
        up.srcOffset        = stagedLockAlloc_.offset;
        up.srcBytesPerRow   = stagedRowPitch_;
        up.srcBytesPerImage = stagedBytes_;
        up.dstTexture       = texture_;
        up.dstSlice         = slice_;
        up.dstLevel         = mipLevel_;
        up.dstOrigin        = MTLOriginMake(0, 0, 0);
        up.dstSize          = MTLSizeMake(desc_.Width, desc_.Height, 1);
        device_->enqueueTextureUpload(up);
        if ((desc_.Usage & D3DM_USAGE_AUTOGENMIPMAP) != 0 && mipLevel_ == 0 && [texture_ mipmapLevelCount] > 1) {
            device_->enqueueGenerateMipmaps(texture_);
        }
        stagedLockAlloc_ = {};
        stagedRowPitch_ = 0;
        stagedBytes_ = 0;
        hasLockedRect_ = false;
        lockReadOnly_ = false;
        return D3D_S_OK;
    }
    if (!lockReadOnly_) {
        uploadCpuToGpu(hasLockedRect_ ? &lockedRect_ : nullptr);
    }
    hasLockedRect_ = false;
    lockReadOnly_ = false;
    return D3D_S_OK;
}

/* ========================================================================= */
/* MtlTextureCommon                                                          */
/* ========================================================================= */

id<MTLTexture> MtlTextureCommon::getSampleView(bool srgb) {
    if (!baseTexture) return nil;

    if (srgb && fmtInfo.srgbPixelFormat != MTLPixelFormatInvalid) {
        if (!sampleViewSrgb) {
            if (fmtInfo.hasSwizzle) {
                sampleViewSrgb = [baseTexture newTextureViewWithPixelFormat:fmtInfo.srgbPixelFormat
                                                               textureType:mtlType
                                                                    levels:NSMakeRange(0, levels)
                                                                    slices:NSMakeRange(0, slices)
                                                                   swizzle:fmtInfo.swizzle];
            } else {
                sampleViewSrgb = [baseTexture newTextureViewWithPixelFormat:fmtInfo.srgbPixelFormat];
            }
        }
        return sampleViewSrgb ? sampleViewSrgb : baseTexture;
    }

    if (!fmtInfo.hasSwizzle) return baseTexture;

    if (!sampleViewLinear) {
        sampleViewLinear = [baseTexture newTextureViewWithPixelFormat:fmtInfo.pixelFormat
                                                          textureType:mtlType
                                                               levels:NSMakeRange(0, levels)
                                                               slices:NSMakeRange(0, slices)
                                                              swizzle:fmtInfo.swizzle];
    }
    return sampleViewLinear ? sampleViewLinear : baseTexture;
}

/* ========================================================================= */
/* MtlTexture9 (2D)                                                          */
/* ========================================================================= */

MtlTexture9::MtlTexture9(MtlDirect3DDevice9 *dev, uint32_t w, uint32_t h, uint32_t levels,
                         uint32_t usage, uint32_t format, uint32_t pool) {
    tex_.device    = dev;
    tex_.d3dFormat = format;
    tex_.fmtInfo   = mapD3dFormat(format);
    tex_.usage     = usage;
    tex_.pool      = pool;
    tex_.width     = std::max(w, 1u);
    tex_.height    = std::max(h, 1u);
    tex_.depth     = 1;
    tex_.levels    = calcMipLevels(tex_.width, tex_.height, 1, levels);
    tex_.slices    = 1;
    tex_.mtlType   = MTLTextureType2D;

    if (pool != D3DM_POOL_SYSTEMMEM && pool != D3DM_POOL_SCRATCH) {
        tex_.baseTexture = createMetalTexture(dev, MTLTextureType2D, tex_.fmtInfo,
                                              tex_.width, tex_.height, 1, tex_.levels, usage);
    }
    if (tex_.baseTexture && isBCPixelFormat(tex_.fmtInfo.pixelFormat) && [tex_.baseTexture pixelFormat] == MTLPixelFormatRGBA8Unorm) { tex_.fmtInfo.srgbPixelFormat = MTLPixelFormatRGBA8Unorm_sRGB; }

    surfaces_.resize(tex_.levels, nullptr);
    uint32_t mw = tex_.width, mh = tex_.height;
    for (uint32_t l = 0; l < tex_.levels; l++) {
        surfaces_[l] = new MtlSurface9(dev, mw, mh, format, usage, pool, 0, 0,
                                       tex_.baseTexture, static_cast<IMtlUnknown *>(this), l, 0);
        mw = std::max(mw >> 1, 1u);
        mh = std::max(mh >> 1, 1u);
    }
}

MtlTexture9::~MtlTexture9() {
    for (auto *s : surfaces_) delete s;
    surfaces_.clear();
    tex_.sampleViewLinear = nil;
    tex_.sampleViewSrgb = nil;
    tex_.baseTexture = nil;
}

MTL_HRESULT MtlTexture9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    tex_.device->AddRef();
    *ppDevice = tex_.device;
    return D3D_S_OK;
}

void MtlTexture9::GenerateMipSubLevels() {
    if (tex_.baseTexture && tex_.levels > 1) {
        tex_.device->enqueueGenerateMipmaps(tex_.baseTexture);
    }
}

MtlSurface9 *MtlTexture9::surfaceAt(uint32_t level) {
    return (level < surfaces_.size()) ? surfaces_[level] : nullptr;
}

MTL_HRESULT MtlTexture9::GetLevelDesc(uint32_t Level, D3DMtlSurfaceDesc *pDesc) {
    if (Level >= surfaces_.size() || !pDesc) return D3D_ERR_INVALIDCALL;
    return surfaces_[Level]->GetDesc(pDesc);
}

MTL_HRESULT MtlTexture9::GetSurfaceLevel(uint32_t Level, IMtlDirect3DSurface9 **ppSurfaceLevel) {
    if (Level >= surfaces_.size() || !ppSurfaceLevel) return D3D_ERR_INVALIDCALL;
    surfaces_[Level]->AddRef();
    *ppSurfaceLevel = surfaces_[Level];
    return D3D_S_OK;
}

MTL_HRESULT MtlTexture9::LockRect(uint32_t Level, D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) {
    if (Level >= surfaces_.size()) return D3D_ERR_INVALIDCALL;
    return surfaces_[Level]->LockRect(pLockedRect, pRect, Flags);
}

MTL_HRESULT MtlTexture9::UnlockRect(uint32_t Level) {
    if (Level >= surfaces_.size()) return D3D_ERR_INVALIDCALL;
    return surfaces_[Level]->UnlockRect();
}

/* ========================================================================= */
/* MtlCubeTexture9                                                           */
/* ========================================================================= */

MtlCubeTexture9::MtlCubeTexture9(MtlDirect3DDevice9 *dev, uint32_t edge, uint32_t levels,
                                 uint32_t usage, uint32_t format, uint32_t pool) {
    tex_.device    = dev;
    tex_.d3dFormat = format;
    tex_.fmtInfo   = mapD3dFormat(format);
    tex_.usage     = usage;
    tex_.pool      = pool;
    tex_.width     = std::max(edge, 1u);
    tex_.height    = std::max(edge, 1u);
    tex_.depth     = 1;
    tex_.levels    = calcMipLevels(tex_.width, tex_.height, 1, levels);
    tex_.slices    = 6;
    tex_.mtlType   = MTLTextureTypeCube;

    if (pool != D3DM_POOL_SYSTEMMEM && pool != D3DM_POOL_SCRATCH) {
        tex_.baseTexture = createMetalTexture(dev, MTLTextureTypeCube, tex_.fmtInfo,
                                              tex_.width, tex_.height, 1, tex_.levels, usage);
    }
    if (tex_.baseTexture && isBCPixelFormat(tex_.fmtInfo.pixelFormat) && [tex_.baseTexture pixelFormat] == MTLPixelFormatRGBA8Unorm) { tex_.fmtInfo.srgbPixelFormat = MTLPixelFormatRGBA8Unorm_sRGB; }

    surfaces_.resize(6u * tex_.levels, nullptr);
    for (uint32_t face = 0; face < 6; face++) {
        uint32_t mw = tex_.width;
        for (uint32_t l = 0; l < tex_.levels; l++) {
            surfaces_[face * tex_.levels + l] = new MtlSurface9(
                dev, mw, mw, format, usage, pool, 0, 0,
                tex_.baseTexture, static_cast<IMtlUnknown *>(this), l, face);
            mw = std::max(mw >> 1, 1u);
        }
    }
}

MtlCubeTexture9::~MtlCubeTexture9() {
    for (auto *s : surfaces_) delete s;
    surfaces_.clear();
    tex_.sampleViewLinear = nil;
    tex_.sampleViewSrgb = nil;
    tex_.baseTexture = nil;
}

MTL_HRESULT MtlCubeTexture9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    tex_.device->AddRef();
    *ppDevice = tex_.device;
    return D3D_S_OK;
}

void MtlCubeTexture9::GenerateMipSubLevels() {
    if (tex_.baseTexture && tex_.levels > 1) {
        tex_.device->enqueueGenerateMipmaps(tex_.baseTexture);
    }
}

MtlSurface9 *MtlCubeTexture9::surfaceAt(uint32_t face, uint32_t level) {
    if (face >= 6 || level >= tex_.levels) return nullptr;
    return surfaces_[face * tex_.levels + level];
}

MTL_HRESULT MtlCubeTexture9::GetLevelDesc(uint32_t Level, D3DMtlSurfaceDesc *pDesc) {
    if (Level >= tex_.levels || !pDesc) return D3D_ERR_INVALIDCALL;
    return surfaces_[Level]->GetDesc(pDesc);
}

MTL_HRESULT MtlCubeTexture9::GetCubeMapSurface(uint32_t FaceType, uint32_t Level, IMtlDirect3DSurface9 **ppCubeMapSurface) {
    MtlSurface9 *s = surfaceAt(FaceType, Level);
    if (!s || !ppCubeMapSurface) return D3D_ERR_INVALIDCALL;
    s->AddRef();
    *ppCubeMapSurface = s;
    return D3D_S_OK;
}

MTL_HRESULT MtlCubeTexture9::LockRect(uint32_t FaceType, uint32_t Level, D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) {
    MtlSurface9 *s = surfaceAt(FaceType, Level);
    if (!s) return D3D_ERR_INVALIDCALL;
    return s->LockRect(pLockedRect, pRect, Flags);
}

MTL_HRESULT MtlCubeTexture9::UnlockRect(uint32_t FaceType, uint32_t Level) {
    MtlSurface9 *s = surfaceAt(FaceType, Level);
    if (!s) return D3D_ERR_INVALIDCALL;
    return s->UnlockRect();
}

/* ========================================================================= */
/* MtlVolume9 & MtlVolumeTexture9                                            */
/* ========================================================================= */

MtlVolume9::MtlVolume9(MtlDirect3DDevice9 *dev, IMtlUnknown *container, id<MTLTexture> tex,
                       uint32_t w, uint32_t h, uint32_t d, uint32_t format,
                       uint32_t usage, uint32_t pool, uint32_t level)
    : device_(dev), container_(container), texture_(tex), mipLevel_(level) {
    desc_.Format = format;
    desc_.Type   = D3DM_RTYPE_VOLUME;
    desc_.Usage  = usage;
    desc_.Pool   = pool;
    desc_.Width  = std::max(w, 1u);
    desc_.Height = std::max(h, 1u);
    desc_.Depth  = std::max(d, 1u);
}

MtlVolume9::~MtlVolume9() {
    texture_ = nil;
}

uint32_t MtlVolume9::AddRef() {
    if (container_) return container_->AddRef();
    return MtlComObject<MtlVolume9, IMtlDirect3DVolume9>::AddRef();
}

uint32_t MtlVolume9::Release() {
    if (container_) return container_->Release();
    return MtlComObject<MtlVolume9, IMtlDirect3DVolume9>::Release();
}

MTL_HRESULT MtlVolume9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlVolume9::GetContainer(const D3DMtlGuid *riid, void **ppContainer) {
    if (!ppContainer) return D3D_ERR_INVALIDCALL;
    if (!container_) return D3D_E_NOINTERFACE;
    return container_->QueryInterface(riid, ppContainer);
}

MTL_HRESULT MtlVolume9::GetDesc(D3DMtlVolumeDesc *pDesc) {
    if (!pDesc) return D3D_ERR_INVALIDCALL;
    *pDesc = desc_;
    return D3D_S_OK;
}

void MtlVolume9::ensureCpuBacking() {
    uint32_t sliceSize = calcSliceSize(desc_.Format, desc_.Width, desc_.Height);
    size_t total = size_t(sliceSize) * desc_.Depth + sliceSize;
    if (cpuData_.size() < total) cpuData_.resize(total, 0);
}

MTL_HRESULT MtlVolume9::LockBox(D3DMtlLockedBox *pLockedVolume, const D3DMtlBox *pBox, uint32_t Flags) {
    if (!pLockedVolume) return D3D_ERR_INVALIDCALL;
    ensureCpuBacking();
    uint32_t rowPitch   = calcRowPitch(desc_.Format, desc_.Width);
    uint32_t slicePitch = calcSliceSize(desc_.Format, desc_.Width, desc_.Height);
    size_t offset = 0;
    if (pBox) {
        MtlFormatInfo fi = mapD3dFormat(desc_.Format);
        uint32_t bx = pBox->Left / std::max(fi.blockWidth, 1u);
        uint32_t by = pBox->Top / std::max(fi.blockHeight, 1u);
        offset = size_t(pBox->Front) * slicePitch + size_t(by) * rowPitch + size_t(bx) * std::max(fi.blockBytes, 1u);
    }
    lockReadOnly_ = (Flags & D3DM_LOCK_READONLY) != 0;
    pLockedVolume->RowPitch   = int32_t(rowPitch);
    pLockedVolume->SlicePitch = int32_t(slicePitch);
    pLockedVolume->pBits      = cpuData_.data() + offset;
    return D3D_S_OK;
}

void MtlVolume9::uploadCpuToGpu() {
    if (!texture_ || cpuData_.empty()) return;
    if (desc_.Pool == D3DM_POOL_SYSTEMMEM || desc_.Pool == D3DM_POOL_SCRATCH) return;

    uint32_t rowPitch   = calcRowPitch(desc_.Format, desc_.Width);
    uint32_t slicePitch = calcSliceSize(desc_.Format, desc_.Width, desc_.Height);
    size_t   totalBytes = size_t(slicePitch) * desc_.Depth;
    auto alloc = device_->ringBuffer().alloc(totalBytes, 16);
    if (!alloc.cpuPtr) return;
    std::memcpy(alloc.cpuPtr, cpuData_.data(), totalBytes);

    PendingTextureUpload up = {};
    up.srcBuffer        = alloc.buffer;
    up.srcOffset        = alloc.offset;
    up.srcBytesPerRow   = rowPitch;
    up.srcBytesPerImage = slicePitch;
    up.dstTexture       = texture_;
    up.dstSlice         = 0;
    up.dstLevel         = mipLevel_;
    up.dstOrigin        = MTLOriginMake(0, 0, 0);
    up.dstSize          = MTLSizeMake(desc_.Width, desc_.Height, desc_.Depth);
    device_->enqueueTextureUpload(up);
}

MTL_HRESULT MtlVolume9::UnlockBox() {
    if (!lockReadOnly_) uploadCpuToGpu();
    lockReadOnly_ = false;
    return D3D_S_OK;
}

MtlVolumeTexture9::MtlVolumeTexture9(MtlDirect3DDevice9 *dev, uint32_t w, uint32_t h, uint32_t d,
                                     uint32_t levels, uint32_t usage, uint32_t format, uint32_t pool) {
    tex_.device    = dev;
    tex_.d3dFormat = format;
    tex_.fmtInfo   = mapD3dFormat(format);
    tex_.usage     = usage;
    tex_.pool      = pool;
    tex_.width     = std::max(w, 1u);
    tex_.height    = std::max(h, 1u);
    tex_.depth     = std::max(d, 1u);
    tex_.levels    = calcMipLevels(tex_.width, tex_.height, tex_.depth, levels);
    tex_.slices    = 1;
    tex_.mtlType   = MTLTextureType3D;

    if (pool != D3DM_POOL_SYSTEMMEM && pool != D3DM_POOL_SCRATCH) {
        tex_.baseTexture = createMetalTexture(dev, MTLTextureType3D, tex_.fmtInfo,
                                              tex_.width, tex_.height, tex_.depth, tex_.levels, usage);
    }

    volumes_.resize(tex_.levels, nullptr);
    uint32_t mw = tex_.width, mh = tex_.height, md = tex_.depth;
    for (uint32_t l = 0; l < tex_.levels; l++) {
        volumes_[l] = new MtlVolume9(dev, static_cast<IMtlUnknown *>(this), tex_.baseTexture,
                                     mw, mh, md, format, usage, pool, l);
        mw = std::max(mw >> 1, 1u);
        mh = std::max(mh >> 1, 1u);
        md = std::max(md >> 1, 1u);
    }
}

MtlVolumeTexture9::~MtlVolumeTexture9() {
    for (auto *v : volumes_) delete v;
    volumes_.clear();
    tex_.sampleViewLinear = nil;
    tex_.sampleViewSrgb = nil;
    tex_.baseTexture = nil;
}

MTL_HRESULT MtlVolumeTexture9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    tex_.device->AddRef();
    *ppDevice = tex_.device;
    return D3D_S_OK;
}

MtlVolume9 *MtlVolumeTexture9::volumeAt(uint32_t level) {
    return (level < volumes_.size()) ? volumes_[level] : nullptr;
}

MTL_HRESULT MtlVolumeTexture9::GetLevelDesc(uint32_t Level, D3DMtlVolumeDesc *pDesc) {
    if (Level >= volumes_.size() || !pDesc) return D3D_ERR_INVALIDCALL;
    return volumes_[Level]->GetDesc(pDesc);
}

MTL_HRESULT MtlVolumeTexture9::GetVolumeLevel(uint32_t Level, IMtlDirect3DVolume9 **ppVolumeLevel) {
    if (Level >= volumes_.size() || !ppVolumeLevel) return D3D_ERR_INVALIDCALL;
    volumes_[Level]->AddRef();
    *ppVolumeLevel = volumes_[Level];
    return D3D_S_OK;
}

MTL_HRESULT MtlVolumeTexture9::LockBox(uint32_t Level, D3DMtlLockedBox *pLockedVolume, const D3DMtlBox *pBox, uint32_t Flags) {
    if (Level >= volumes_.size()) return D3D_ERR_INVALIDCALL;
    return volumes_[Level]->LockBox(pLockedVolume, pBox, Flags);
}

MTL_HRESULT MtlVolumeTexture9::UnlockBox(uint32_t Level) {
    if (Level >= volumes_.size()) return D3D_ERR_INVALIDCALL;
    return volumes_[Level]->UnlockBox();
}

MtlTextureCommon *getTextureCommon(IMtlDirect3DBaseTexture9 *baseTex) {
    if (!baseTex) return nullptr;
    switch (baseTex->GetType()) {
        case D3DM_RTYPE_TEXTURE:       return &static_cast<MtlTexture9 *>(baseTex)->common();
        case D3DM_RTYPE_CUBETEXTURE:   return &static_cast<MtlCubeTexture9 *>(baseTex)->common();
        case D3DM_RTYPE_VOLUMETEXTURE: return &static_cast<MtlVolumeTexture9 *>(baseTex)->common();
        default:                       return nullptr;
    }
}

/* ========================================================================= */
/* MtlVertexDeclaration9, Shaders, Queries                                   */
/* ========================================================================= */

MtlVertexDeclaration9::MtlVertexDeclaration9(MtlDirect3DDevice9 *dev, const D3DMtlVertexElement *elems)
    : device_(dev) {
    if (elems) {
        for (size_t i = 0; i < 64; i++) {
            if (elems[i].Stream == 0xFF || elems[i].Type == D3DM_DECLTYPE_UNUSED) break;
            elements_.push_back(elems[i]);
        }
    }
    hash_ = elements_.empty() ? 1ull : fnv1a64Bytes(elements_.data(), elements_.size() * sizeof(D3DMtlVertexElement));
}

MtlVertexDeclaration9::~MtlVertexDeclaration9() = default;

MTL_HRESULT MtlVertexDeclaration9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlVertexDeclaration9::GetDeclaration(D3DMtlVertexElement *pElement, uint32_t *pNumElements) {
    uint32_t count = uint32_t(elements_.size()) + 1u;
    if (pNumElements) *pNumElements = count;
    if (pElement) {
        if (!elements_.empty()) {
            std::memcpy(pElement, elements_.data(), elements_.size() * sizeof(D3DMtlVertexElement));
        }
        pElement[elements_.size()] = { 0xFF, 0, D3DM_DECLTYPE_UNUSED, 0, 0, 0 };
    }
    return D3D_S_OK;
}

MtlVertexShader9::MtlVertexShader9(MtlDirect3DDevice9 *dev, std::shared_ptr<MtlParsedShader> shader)
    : device_(dev), shader_(std::move(shader)) {}

MtlVertexShader9::~MtlVertexShader9() = default;

MTL_HRESULT MtlVertexShader9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlVertexShader9::GetFunction(void *pData, uint32_t *pSizeOfData) {
    if (!pSizeOfData) return D3D_ERR_INVALIDCALL;
    uint32_t bytes = shader_ ? uint32_t(shader_->rawBytecode.size() * sizeof(uint32_t)) : 0u;
    if (!pData) {
        *pSizeOfData = bytes;
        return D3D_S_OK;
    }
    if (*pSizeOfData < bytes) return D3D_ERR_INVALIDCALL;
    if (bytes > 0) std::memcpy(pData, shader_->rawBytecode.data(), bytes);
    *pSizeOfData = bytes;
    return D3D_S_OK;
}

MtlPixelShader9::MtlPixelShader9(MtlDirect3DDevice9 *dev, std::shared_ptr<MtlParsedShader> shader)
    : device_(dev), shader_(std::move(shader)) {}

MtlPixelShader9::~MtlPixelShader9() = default;

MTL_HRESULT MtlPixelShader9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlPixelShader9::GetFunction(void *pData, uint32_t *pSizeOfData) {
    if (!pSizeOfData) return D3D_ERR_INVALIDCALL;
    uint32_t bytes = shader_ ? uint32_t(shader_->rawBytecode.size() * sizeof(uint32_t)) : 0u;
    if (!pData) {
        *pSizeOfData = bytes;
        return D3D_S_OK;
    }
    if (*pSizeOfData < bytes) return D3D_ERR_INVALIDCALL;
    if (bytes > 0) std::memcpy(pData, shader_->rawBytecode.data(), bytes);
    *pSizeOfData = bytes;
    return D3D_S_OK;
}

MtlQuery9::MtlQuery9(MtlDirect3DDevice9 *dev, uint32_t type)
    : device_(dev), type_(type) {}

MtlQuery9::~MtlQuery9() = default;

MTL_HRESULT MtlQuery9::GetDevice(IMtlDirect3DDevice9 **ppDevice) {
    if (!ppDevice) return D3D_ERR_INVALIDCALL;
    device_->AddRef();
    *ppDevice = device_;
    return D3D_S_OK;
}

MTL_HRESULT MtlQuery9::Issue(uint32_t dwIssueFlags) {
    consecutiveMisses_ = 0;
    if (type_ == D3DM_QUERYTYPE_OCCLUSION) {
        if (dwIssueFlags & D3DM_ISSUE_BEGIN) {
            visSlot_ = device_->beginOcclusionQuery();
            active_ = true;
            issued_ = false;
            return D3D_S_OK;
        }
        if (dwIssueFlags & D3DM_ISSUE_END) {
            if (active_) {
                issuedSeq_ = device_->endOcclusionQuery(visSlot_);
                active_ = false;
                issued_ = true;
            } else {
                issuedSeq_ = device_->issueEventQuery();
                issued_ = true;
            }
            return D3D_S_OK;
        }
        return D3D_S_OK;
    }

    if (type_ == D3DM_QUERYTYPE_EVENT) {
        if (dwIssueFlags & D3DM_ISSUE_END) {
            issuedSeq_ = device_->issueEventQuery();
            issued_ = true;
        }
        return D3D_S_OK;
    }

    return D3D_S_OK;
}

MTL_HRESULT MtlQuery9::GetData(void *pData, uint32_t dwSize, uint32_t dwGetDataFlags) {
    if (!issued_) {
        if (pData && dwSize >= 4) {
            uint32_t v = (type_ == D3DM_QUERYTYPE_EVENT) ? 1u : 0u;
            std::memcpy(pData, &v, 4);
        }
        return D3D_S_OK;
    }

    const bool trackPerf = device_->perfLogEnabled();
    auto t0 = trackPerf ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    bool hadFlush = (dwGetDataFlags & D3DM_GETDATA_FLUSH) != 0;
    bool trigFlush = false;

    if (device_->completedCommandSeq() < issuedSeq_) {
        /* Only flush when the command buffer holding this query has not been committed yet;
           otherwise UE3's busy-poll loop would lock and split unrelated subsequent passes. */
        if (hadFlush && device_->lastCommittedSeq() < issuedSeq_) {
            trigFlush = true;
            device_->flushCommands(false);
        }
        if (device_->completedCommandSeq() < issuedSeq_) {
            /* Keep non-blocking first probes instantaneous (S_FALSE), then block cleanly on the
               command-completion condition variable when UE3 enters a blocking GetData spin loop. */
            if (hadFlush && consecutiveMisses_ >= 1u) {
                device_->waitForCommandSeq(issuedSeq_, 16u);
            } else {
                consecutiveMisses_++;
            }
            if (device_->completedCommandSeq() < issuedSeq_) {
                if (trackPerf) {
                    uint64_t ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - t0).count());
                    device_->recordPerfQueryWait(ns, hadFlush, trigFlush, true);
                }
                return D3D_S_FALSE;
            }
        }
    }
    consecutiveMisses_ = 0;
    if (trackPerf) {
        uint64_t ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - t0).count());
        device_->recordPerfQueryWait(ns, hadFlush, trigFlush, false);
    }

    if (pData && dwSize >= 4) {
        if (type_ == D3DM_QUERYTYPE_OCCLUSION) {
            uint64_t count = device_->readVisibilityResult(visSlot_);
            uint32_t pixels = (count > 0xFFFFFFFFull) ? 0xFFFFFFFFu : uint32_t(count);
            std::memcpy(pData, &pixels, 4);
        } else {
            uint32_t done = 1u;
            std::memcpy(pData, &done, 4);
        }
    }
    return D3D_S_OK;
}

} // namespace mtl_d3d9
