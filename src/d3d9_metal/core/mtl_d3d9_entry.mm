#import <Metal/Metal.h>
#include <SDL3/SDL.h>

#include "d3d9_metal_com.h"
#include "mtl_d3d9_device.h"
#include "mtl_format.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <vector>

namespace mtl_d3d9 {

struct DisplayModeQuery {
    std::vector<D3DMtlDisplayMode> modes;
    D3DMtlDisplayMode desktop = { 1280, 720, 60, D3DM_FMT_X8R8G8B8 };
};

static void queryDisplayModesOnMain(void *userdata) {
    auto *q = static_cast<DisplayModeQuery *>(userdata);
    SDL_DisplayID disp = SDL_GetPrimaryDisplay();
    if (!disp) return;

    const SDL_DisplayMode *desk = SDL_GetDesktopDisplayMode(disp);
    if (desk && desk->w > 0 && desk->h > 0) {
        float scale = (desk->pixel_density > 0.5f) ? desk->pixel_density : 1.0f;
        q->desktop.Width       = uint32_t(desk->w * scale + 0.5f);
        q->desktop.Height      = uint32_t(desk->h * scale + 0.5f);
        q->desktop.RefreshRate = (desk->refresh_rate > 1.0f) ? uint32_t(desk->refresh_rate + 0.5f) : 60u;
        q->desktop.Format      = D3DM_FMT_X8R8G8B8;
    }

    int count = 0;
    SDL_DisplayMode **list = SDL_GetFullscreenDisplayModes(disp, &count);
    if (list) {
        for (int i = 0; i < count; i++) {
            const SDL_DisplayMode *m = list[i];
            if (!m || m->w < 640 || m->h < 480) continue;
            float scale = (m->pixel_density > 0.5f) ? m->pixel_density : 1.0f;
            uint32_t rw = uint32_t(m->w * scale + 0.5f);
            uint32_t rh = uint32_t(m->h * scale + 0.5f);
            uint32_t hz = (m->refresh_rate > 1.0f) ? uint32_t(m->refresh_rate + 0.5f) : 60u;
            bool dup = false;
            for (const auto &e : q->modes) {
                if (e.Width == rw && e.Height == rh && e.RefreshRate == hz) { dup = true; break; }
            }
            if (!dup) {
                q->modes.push_back({ rw, rh, hz, D3DM_FMT_X8R8G8B8 });
            }
        }
        SDL_free(list);
    }

    if (q->modes.empty()) {
        q->modes.push_back(q->desktop);
    }
}

class MtlDirect3D9 final : public MtlComObject<MtlDirect3D9, IMtlDirect3D9> {
public:
    MtlDirect3D9(id<MTLDevice> dev, uint32_t sdkVer)
        : device_(dev), sdkVersion_(sdkVer) {
        DisplayModeQuery q;
        SDL_RunOnMainThread(queryDisplayModesOnMain, &q, true);
        modes_ = std::move(q.modes);
        desktopMode_ = q.desktop;
    }

    MTL_HRESULT RegisterSoftwareDevice(void *) override { return D3D_ERR_INVALIDCALL; }
    uint32_t    GetAdapterCount() override { return 1; }

    MTL_HRESULT GetAdapterIdentifier(uint32_t adapter, uint32_t, D3DMtlAdapterIdentifier *id) override {
        if (adapter != 0 || !id) return D3D_ERR_INVALIDCALL;
        std::memset(id, 0, sizeof(*id));
        snprintf(id->Driver, sizeof(id->Driver), "AppleMetal");
        snprintf(id->Description, sizeof(id->Description), "%s (Native Metal)",
                 device_ ? [[device_ name] UTF8String] : "Apple Metal GPU");
        snprintf(id->DeviceName, sizeof(id->DeviceName), "\\\\.\\DISPLAY1");
        id->DriverVersion = (30ull << 48) | (1ull << 32) | (1ull << 16) | 1ull;
        /* Report a Bucket-5 PCI ID from DefaultCompat.ini so UE3 enables full quality + PhysXEnhanced on first launch. */
        id->VendorId = 0x10DEu;
        id->DeviceId = 0x05E1u;
        return D3D_S_OK;
    }

    uint32_t GetAdapterModeCount(uint32_t adapter, uint32_t fmt) override {
        if (adapter != 0) return 0;
        if (fmt != D3DM_FMT_X8R8G8B8 && fmt != D3DM_FMT_A8R8G8B8) return 0;
        return uint32_t(modes_.size());
    }

    MTL_HRESULT EnumAdapterModes(uint32_t adapter, uint32_t fmt, uint32_t mode, D3DMtlDisplayMode *out) override {
        if (adapter != 0 || !out || mode >= modes_.size()) return D3D_ERR_INVALIDCALL;
        if (fmt != D3DM_FMT_X8R8G8B8 && fmt != D3DM_FMT_A8R8G8B8) return D3D_ERR_INVALIDCALL;
        *out = modes_[mode];
        out->Format = fmt;
        return D3D_S_OK;
    }

    MTL_HRESULT GetAdapterDisplayMode(uint32_t adapter, D3DMtlDisplayMode *out) override {
        if (adapter != 0 || !out) return D3D_ERR_INVALIDCALL;
        *out = desktopMode_;
        return D3D_S_OK;
    }

    MTL_HRESULT CheckDeviceType(uint32_t adapter, uint32_t devType, uint32_t adapterFmt, uint32_t bbFmt, uint32_t windowed) override {
        (void)devType; (void)windowed;
        if (adapter != 0) return D3D_ERR_INVALIDCALL;
        if (adapterFmt != D3DM_FMT_X8R8G8B8 && adapterFmt != D3DM_FMT_A8R8G8B8) return D3D_ERR_NOTAVAILABLE;
        if (bbFmt != D3DM_FMT_X8R8G8B8 && bbFmt != D3DM_FMT_A8R8G8B8 && bbFmt != D3DM_FMT_A2R10G10B10) return D3D_ERR_NOTAVAILABLE;
        return D3D_S_OK;
    }

    MTL_HRESULT CheckDeviceFormat(uint32_t adapter, uint32_t devType, uint32_t adapterFmt,
                                  uint32_t usage, uint32_t rtype, uint32_t checkFmt) override {
        (void)devType; (void)adapterFmt;
        if (adapter != 0) return D3D_ERR_INVALIDCALL;

        /* Special D3DFMT_NULL render target (UE3 shadow maps) */
        if (checkFmt == D3DM_FMT_NULL) {
            return (usage & D3DM_USAGE_RENDERTARGET) ? D3D_S_OK : D3D_ERR_NOTAVAILABLE;
        }

        MtlFormatInfo fi = mapD3dFormat(checkFmt);
        if (fi.pixelFormat == MTLPixelFormatInvalid) return D3D_ERR_NOTAVAILABLE;

        bool isCompressed = (fi.blockWidth > 1 || fi.blockHeight > 1);

        if (usage & D3DM_USAGE_DEPTHSTENCIL) {
            if (!fi.isDepth) return D3D_ERR_NOTAVAILABLE;
            if (rtype != D3DM_RTYPE_SURFACE && rtype != D3DM_RTYPE_TEXTURE) return D3D_ERR_NOTAVAILABLE;
            return D3D_S_OK;
        }

        if (usage & D3DM_USAGE_RENDERTARGET) {
            if (fi.isDepth || isCompressed) return D3D_ERR_NOTAVAILABLE;
            if (checkFmt == D3DM_FMT_A4R4G4B4) return D3D_ERR_NOTAVAILABLE;
        }

        if (usage & D3DM_USAGE_QUERY_SRGBREAD) {
            if (fi.srgbPixelFormat == MTLPixelFormatInvalid) return D3D_ERR_NOTAVAILABLE;
        }

        if (usage & D3DM_USAGE_QUERY_SRGBWRITE) {
            if (fi.srgbPixelFormat == MTLPixelFormatInvalid || isCompressed || fi.isDepth) {
                return D3D_ERR_NOTAVAILABLE;
            }
        }

        if (usage & D3DM_USAGE_QUERY_POSTPIXELSHADER_BLEND) {
            if (isCompressed || fi.isDepth) return D3D_ERR_NOTAVAILABLE;
        }

        if (usage & D3DM_USAGE_AUTOGENMIPMAP) {
            if (isCompressed || fi.isDepth) return D3D_OK_NOAUTOGEN;
        }

        if (rtype == D3DM_RTYPE_VOLUMETEXTURE && fi.isDepth) {
            return D3D_ERR_NOTAVAILABLE;
        }

        return D3D_S_OK;
    }

    MTL_HRESULT CheckDeviceMultiSampleType(uint32_t adapter, uint32_t devType, uint32_t surfFmt,
                                           uint32_t windowed, uint32_t ms, uint32_t *pQual) override {
        (void)devType; (void)windowed;
        if (adapter != 0) return D3D_ERR_INVALIDCALL;
        if (pQual) *pQual = 0;
        MtlFormatInfo fi = mapD3dFormat(surfFmt);
        if (!fi.isNullFormat && fi.pixelFormat == MTLPixelFormatInvalid) return D3D_ERR_NOTAVAILABLE;
        return (ms <= 1) ? D3D_S_OK : D3D_ERR_NOTAVAILABLE;
    }

    MTL_HRESULT CheckDepthStencilMatch(uint32_t adapter, uint32_t devType, uint32_t adapterFmt,
                                       uint32_t rtFmt, uint32_t dsFmt) override {
        (void)devType; (void)adapterFmt;
        if (adapter != 0) return D3D_ERR_INVALIDCALL;
        MtlFormatInfo rt = mapD3dFormat(rtFmt);
        MtlFormatInfo ds = mapD3dFormat(dsFmt);
        if ((!rt.isNullFormat && rt.pixelFormat == MTLPixelFormatInvalid) || !ds.isDepth) {
            return D3D_ERR_NOTAVAILABLE;
        }
        return D3D_S_OK;
    }

    MTL_HRESULT CheckDeviceFormatConversion(uint32_t adapter, uint32_t devType,
                                            uint32_t srcFmt, uint32_t dstFmt) override {
        (void)devType;
        if (adapter != 0) return D3D_ERR_INVALIDCALL;
        MtlFormatInfo s = mapD3dFormat(srcFmt);
        MtlFormatInfo d = mapD3dFormat(dstFmt);
        if (s.pixelFormat == MTLPixelFormatInvalid || d.pixelFormat == MTLPixelFormatInvalid) {
            return D3D_ERR_NOTAVAILABLE;
        }
        return D3D_S_OK;
    }

    MTL_HRESULT GetDeviceCaps(uint32_t adapter, uint32_t devType, D3DMtlCaps9 *c) override {
        if (adapter != 0 || !c) return D3D_ERR_INVALIDCALL;
        std::memset(c, 0, sizeof(*c));

        c->DeviceType               = devType ? devType : 1u; /* D3DDEVTYPE_HAL */
        c->AdapterOrdinal           = adapter;
        c->Caps                     = 0x00020000u; /* D3DCAPS_READ_SCANLINE */
        c->Caps2                    = 0x600A0000u; /* FULLSCREENGAMMA | DYNAMICTEXTURES | CANAUTOGENMIPMAP | CANSHARERESOURCE */
        c->Caps3                    = 0x000003A0u; /* ALPHA_FULLSCREEN_FLIP_OR_DISCARD | LINEAR_TO_SRGB_PRESENTATION | COPY_TO_VIDMEM | COPY_TO_SYSTEMMEM */
        c->PresentationIntervals    = 0x8000000Fu; /* IMMEDIATE | ONE | TWO | THREE | FOUR */
        c->CursorCaps               = 0x00000001u; /* COLOR */
        c->DevCaps                  = 0x001BBEF0u; /* HW T&L, PureDevice, DrawPrimitives2Ex, etc. */
        c->PrimitiveMiscCaps        = 0x003FCEF2u; /* Cull, ColorWriteEnable, BlendOp, SeparateAlpha, IndepWriteMasks, MRT, PostBlendSRGB */
        c->RasterCaps               = 0x07732191u; /* ZTest, Fog, Aniso, Scissor, SlopeScaleDepthBias, DepthBias */
        c->ZCmpCaps                 = 0x000000FFu;
        c->SrcBlendCaps             = 0x00003FFFu;
        c->DestBlendCaps            = 0x00003FFFu;
        c->AlphaCmpCaps             = 0x000000FFu;
        c->ShadeCaps                = 0x00084208u;
        c->TextureCaps              = 0x0001ECE5u; /* Full NPOT, Cube, Volume, Mipmap, Projected */
        c->TextureFilterCaps        = 0x03030700u; /* Point, Linear, Aniso, MipPoint, MipLinear */
        c->CubeTextureFilterCaps    = 0x03030700u;
        c->VolumeTextureFilterCaps  = 0x03030700u;
        c->TextureAddressCaps       = 0x0000003Fu; /* Wrap, Mirror, Clamp, Border, IndependentUV, MirrorOnce */
        c->VolumeTextureAddressCaps = 0x0000003Fu;
        c->LineCaps                 = 0x0000001Fu;

        c->MaxTextureWidth          = 8192u;
        c->MaxTextureHeight         = 8192u;
        c->MaxVolumeExtent          = 2048u;
        c->MaxTextureRepeat         = 8192u;
        c->MaxTextureAspectRatio    = 8192u;
        c->MaxAnisotropy            = 16u;
        c->MaxVertexW               = 1e10f;
        c->GuardBandLeft            = -32768.0f;
        c->GuardBandTop             = -32768.0f;
        c->GuardBandRight           = 32768.0f;
        c->GuardBandBottom          = 32768.0f;
        c->ExtentsAdjust            = 0.0f;

        c->StencilCaps              = 0x000001FFu; /* All ops + TwoSided */
        c->FVFCaps                  = 0x00180008u;
        c->TextureOpCaps            = 0x03FFFFFFu;
        c->MaxTextureBlendStages    = 8u;
        c->MaxSimultaneousTextures  = 8u;
        c->VertexProcessingCaps     = 0x0000017Bu;
        c->MaxActiveLights          = 8u;
        c->MaxUserClipPlanes        = 6u;
        c->MaxVertexBlendMatrices   = 4u;
        c->MaxVertexBlendMatrixIndex = 0u;
        c->MaxPointSize             = 64.0f;
        c->MaxPrimitiveCount        = 0x00FFFFFFu;
        c->MaxVertexIndex           = 0x00FFFFFFu;
        c->MaxStreams               = 16u;
        c->MaxStreamStride          = 508u;

        c->VertexShaderVersion      = 0xFFFE0300u; /* vs_3_0 */
        c->MaxVertexShaderConst     = 256u;
        c->PixelShaderVersion       = 0xFFFF0300u; /* ps_3_0 */
        c->PixelShader1xMaxValue    = 65504.0f;
        c->DevCaps2                 = 0x00000051u; /* STREAMOFFSET | VERTEXELEMENTSCANSHARESTREAMOFFSET | CAN_STRETCHRECT_FROM_TEXTURES */
        c->MaxNpatchTessellationLevel = 0.0f;
        c->MasterAdapterOrdinal     = 0u;
        c->AdapterOrdinalInGroup    = 0u;
        c->NumberOfAdaptersInGroup  = 1u;
        c->DeclTypes                = 0x000003FFu;
        c->NumSimultaneousRTs       = 4u;
        c->StretchRectFilterCaps    = 0x03000300u;

        c->VS20Caps.Caps                    = 1u;  /* D3DVS20CAPS_PREDICATION */
        c->VS20Caps.DynamicFlowControlDepth = 24;
        c->VS20Caps.NumTemps                = 32;
        c->VS20Caps.StaticFlowControlDepth  = 4;

        c->PS20Caps.Caps                    = 0x1Fu; /* ArbitrarySwizzle | GradientInstructions | Predication | NoDependentReadLimit | NoTexInstructionLimit */
        c->PS20Caps.DynamicFlowControlDepth = 24;
        c->PS20Caps.NumTemps                = 32;
        c->PS20Caps.StaticFlowControlDepth  = 4;
        c->PS20Caps.NumInstructionSlots     = 512;

        c->VertexTextureFilterCaps            = 0x03000300u;
        c->MaxVShaderInstructionsExecuted     = 65535u;
        c->MaxPShaderInstructionsExecuted     = 65535u;
        c->MaxVertexShader30InstructionSlots  = 4096u;
        c->MaxPixelShader30InstructionSlots   = 4096u;
        return D3D_S_OK;
    }

    void *GetAdapterMonitor(uint32_t) override { return nullptr; }

    MTL_HRESULT CreateDevice(uint32_t adapter, uint32_t devType, void *focusWindow,
                             uint32_t behaviorFlags, D3DMtlPresentParameters *pp,
                             IMtlDirect3DDevice9 **ppReturnedDevice) override {
        if (adapter != 0 || !pp || !ppReturnedDevice) return D3D_ERR_INVALIDCALL;
        *ppReturnedDevice = nullptr;

        auto *dev = new MtlDirect3DDevice9(this, device_, adapter, devType, focusWindow, behaviorFlags, *pp);
        if (!dev->initialize()) {
            dev->Release();
            return D3D_ERR_NOTAVAILABLE;
        }
        IMtlDirect3DSwapChain9 *sc = nullptr;
        if (dev->GetSwapChain(0, &sc) == D3D_S_OK && sc) {
            sc->GetPresentParameters(pp);
            sc->Release();
        }
        *ppReturnedDevice = dev;
        return D3D_S_OK;
    }

private:
    id<MTLDevice> device_;
    uint32_t sdkVersion_;
    std::vector<D3DMtlDisplayMode> modes_;
    D3DMtlDisplayMode desktopMode_ = { 1280, 720, 60, D3DM_FMT_X8R8G8B8 };
};

} // namespace mtl_d3d9

extern "C" void host_stall_hook(int begin);

extern "C" void *mtl_d3d9_create(uint32_t sdk_version) {
    mtl_d3d9::MtlShaderCompiler::setStallHook(host_stall_hook);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        fprintf(stderr, "RunnerMetal: MTLCreateSystemDefaultDevice() failed\n");
        return nullptr;
    }
    fprintf(stderr, "RunnerMetal: native Metal device '%s' initialized (sdk=%u)\n",
            [[dev name] UTF8String], sdk_version);
    return static_cast<IMtlDirect3D9 *>(new mtl_d3d9::MtlDirect3D9(dev, sdk_version));
}
