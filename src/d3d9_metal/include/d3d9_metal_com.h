#pragma once

#include "d3d9_metal_types.h"
#include <atomic>
#include <cstring>

/* Pure-virtual COM interface hierarchy whose vtable slot indices match
   src/host_macos/runtime/rt_d3d9_idx.h and rt_d3d9_gen.c 1:1 on LP64.
   NOTE: No virtual destructors anywhere in this hierarchy so the Itanium
   C++ ABI does not insert extra destructor slots into the COM vtable. */

class IMtlUnknown {
public:
    virtual MTL_HRESULT QueryInterface(const D3DMtlGuid *riid, void **ppv) = 0;
    virtual uint32_t AddRef() = 0;
    virtual uint32_t Release() = 0;
};

template <typename Derived, typename Base>
class MtlComObject : public Base {
public:
    MtlComObject() : refcount_(1) {}

    uint32_t AddRef() override {
        return refcount_.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    uint32_t Release() override {
        uint32_t n = refcount_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (n == 0) {
            delete static_cast<Derived *>(this);
        }
        return n;
    }

    MTL_HRESULT QueryInterface(const D3DMtlGuid *riid, void **ppv) override {
        if (!ppv) return D3D_ERR_INVALIDCALL;
        (void)riid;
        this->AddRef();
        *ppv = static_cast<Base *>(this);
        return D3D_S_OK;
    }

protected:
    std::atomic<uint32_t> refcount_;
};

class IMtlDirect3DDevice9;
class IMtlDirect3DSwapChain9;
class IMtlDirect3DSurface9;
class IMtlDirect3DVolume9;
class IMtlDirect3DVertexBuffer9;
class IMtlDirect3DIndexBuffer9;
class IMtlDirect3DBaseTexture9;
class IMtlDirect3DTexture9;
class IMtlDirect3DCubeTexture9;
class IMtlDirect3DVolumeTexture9;
class IMtlDirect3DVertexDeclaration9;
class IMtlDirect3DVertexShader9;
class IMtlDirect3DPixelShader9;
class IMtlDirect3DStateBlock9;
class IMtlDirect3DQuery9;

class IMtlDirect3D9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT RegisterSoftwareDevice(void *pInitializeFunction) = 0;
    virtual uint32_t    GetAdapterCount() = 0;
    virtual MTL_HRESULT GetAdapterIdentifier(uint32_t Adapter, uint32_t Flags, D3DMtlAdapterIdentifier *pIdentifier) = 0;
    virtual uint32_t    GetAdapterModeCount(uint32_t Adapter, uint32_t Format) = 0;
    virtual MTL_HRESULT EnumAdapterModes(uint32_t Adapter, uint32_t Format, uint32_t Mode, D3DMtlDisplayMode *pMode) = 0;
    virtual MTL_HRESULT GetAdapterDisplayMode(uint32_t Adapter, D3DMtlDisplayMode *pMode) = 0;
    virtual MTL_HRESULT CheckDeviceType(uint32_t Adapter, uint32_t DevType, uint32_t AdapterFormat, uint32_t BackBufferFormat, uint32_t bWindowed) = 0;
    virtual MTL_HRESULT CheckDeviceFormat(uint32_t Adapter, uint32_t DeviceType, uint32_t AdapterFormat, uint32_t Usage, uint32_t RType, uint32_t CheckFormat) = 0;
    virtual MTL_HRESULT CheckDeviceMultiSampleType(uint32_t Adapter, uint32_t DeviceType, uint32_t SurfaceFormat, uint32_t Windowed, uint32_t MultiSampleType, uint32_t *pQualityLevels) = 0;
    virtual MTL_HRESULT CheckDepthStencilMatch(uint32_t Adapter, uint32_t DeviceType, uint32_t AdapterFormat, uint32_t RenderTargetFormat, uint32_t DepthStencilFormat) = 0;
    virtual MTL_HRESULT CheckDeviceFormatConversion(uint32_t Adapter, uint32_t DeviceType, uint32_t SourceFormat, uint32_t TargetFormat) = 0;
    virtual MTL_HRESULT GetDeviceCaps(uint32_t Adapter, uint32_t DeviceType, D3DMtlCaps9 *pCaps) = 0;
    virtual void       *GetAdapterMonitor(uint32_t Adapter) = 0;
    virtual MTL_HRESULT CreateDevice(uint32_t Adapter, uint32_t DeviceType, void *hFocusWindow, uint32_t BehaviorFlags, D3DMtlPresentParameters *pPresentationParameters, IMtlDirect3DDevice9 **ppReturnedDeviceInterface) = 0;
};

class IMtlDirect3DDevice9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT TestCooperativeLevel() = 0;
    virtual uint32_t    GetAvailableTextureMem() = 0;
    virtual MTL_HRESULT EvictManagedResources() = 0;
    virtual MTL_HRESULT GetDirect3D(IMtlDirect3D9 **ppD3D9) = 0;
    virtual MTL_HRESULT GetDeviceCaps(D3DMtlCaps9 *pCaps) = 0;
    virtual MTL_HRESULT GetDisplayMode(uint32_t iSwapChain, D3DMtlDisplayMode *pMode) = 0;
    virtual MTL_HRESULT GetCreationParameters(D3DMtlCreationParameters *pParameters) = 0;
    virtual MTL_HRESULT SetCursorProperties(uint32_t XHotSpot, uint32_t YHotSpot, IMtlDirect3DSurface9 *pCursorBitmap) = 0;
    virtual void        SetCursorPosition(int32_t X, int32_t Y, uint32_t Flags) = 0;
    virtual uint32_t    ShowCursor(uint32_t bShow) = 0;
    virtual MTL_HRESULT CreateAdditionalSwapChain(D3DMtlPresentParameters *pPresentationParameters, IMtlDirect3DSwapChain9 **pSwapChain) = 0;
    virtual MTL_HRESULT GetSwapChain(uint32_t iSwapChain, IMtlDirect3DSwapChain9 **pSwapChain) = 0;
    virtual uint32_t    GetNumberOfSwapChains() = 0;
    virtual MTL_HRESULT Reset(D3DMtlPresentParameters *pPresentationParameters) = 0;
    virtual MTL_HRESULT Present(const D3DMtlRect *pSourceRect, const D3DMtlRect *pDestRect, void *hDestWindowOverride, const void *pDirtyRegion) = 0;
    virtual MTL_HRESULT GetBackBuffer(uint32_t iSwapChain, uint32_t iBackBuffer, uint32_t Type, IMtlDirect3DSurface9 **ppBackBuffer) = 0;
    virtual MTL_HRESULT GetRasterStatus(uint32_t iSwapChain, D3DMtlRasterStatus *pRasterStatus) = 0;
    virtual MTL_HRESULT SetDialogBoxMode(uint32_t bEnableDialogs) = 0;
    virtual void        SetGammaRamp(uint32_t iSwapChain, uint32_t Flags, const D3DMtlGammaRamp *pRamp) = 0;
    virtual void        GetGammaRamp(uint32_t iSwapChain, D3DMtlGammaRamp *pRamp) = 0;
    virtual MTL_HRESULT CreateTexture(uint32_t Width, uint32_t Height, uint32_t Levels, uint32_t Usage, uint32_t Format, uint32_t Pool, IMtlDirect3DTexture9 **ppTexture, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateVolumeTexture(uint32_t Width, uint32_t Height, uint32_t Depth, uint32_t Levels, uint32_t Usage, uint32_t Format, uint32_t Pool, IMtlDirect3DVolumeTexture9 **ppVolumeTexture, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateCubeTexture(uint32_t EdgeLength, uint32_t Levels, uint32_t Usage, uint32_t Format, uint32_t Pool, IMtlDirect3DCubeTexture9 **ppCubeTexture, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateVertexBuffer(uint32_t Length, uint32_t Usage, uint32_t FVF, uint32_t Pool, IMtlDirect3DVertexBuffer9 **ppVertexBuffer, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateIndexBuffer(uint32_t Length, uint32_t Usage, uint32_t Format, uint32_t Pool, IMtlDirect3DIndexBuffer9 **ppIndexBuffer, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateRenderTarget(uint32_t Width, uint32_t Height, uint32_t Format, uint32_t MultiSample, uint32_t MultisampleQuality, uint32_t Lockable, IMtlDirect3DSurface9 **ppSurface, void **pSharedHandle) = 0;
    virtual MTL_HRESULT CreateDepthStencilSurface(uint32_t Width, uint32_t Height, uint32_t Format, uint32_t MultiSample, uint32_t MultisampleQuality, uint32_t Discard, IMtlDirect3DSurface9 **ppSurface, void **pSharedHandle) = 0;
    virtual MTL_HRESULT UpdateSurface(IMtlDirect3DSurface9 *pSourceSurface, const D3DMtlRect *pSourceRect, IMtlDirect3DSurface9 *pDestinationSurface, const D3DMtlPoint *pDestPoint) = 0;
    virtual MTL_HRESULT UpdateTexture(IMtlDirect3DBaseTexture9 *pSourceTexture, IMtlDirect3DBaseTexture9 *pDestinationTexture) = 0;
    virtual MTL_HRESULT GetRenderTargetData(IMtlDirect3DSurface9 *pRenderTarget, IMtlDirect3DSurface9 *pDestSurface) = 0;
    virtual MTL_HRESULT GetFrontBufferData(uint32_t iSwapChain, IMtlDirect3DSurface9 *pDestSurface) = 0;
    virtual MTL_HRESULT StretchRect(IMtlDirect3DSurface9 *pSourceSurface, const D3DMtlRect *pSourceRect, IMtlDirect3DSurface9 *pDestSurface, const D3DMtlRect *pDestRect, uint32_t Filter) = 0;
    virtual MTL_HRESULT ColorFill(IMtlDirect3DSurface9 *pSurface, const D3DMtlRect *pRect, D3DCOLOR_T color) = 0;
    virtual MTL_HRESULT CreateOffscreenPlainSurface(uint32_t Width, uint32_t Height, uint32_t Format, uint32_t Pool, IMtlDirect3DSurface9 **ppSurface, void **pSharedHandle) = 0;
    virtual MTL_HRESULT SetRenderTarget(uint32_t RenderTargetIndex, IMtlDirect3DSurface9 *pRenderTarget) = 0;
    virtual MTL_HRESULT GetRenderTarget(uint32_t RenderTargetIndex, IMtlDirect3DSurface9 **ppRenderTarget) = 0;
    virtual MTL_HRESULT SetDepthStencilSurface(IMtlDirect3DSurface9 *pNewZStencil) = 0;
    virtual MTL_HRESULT GetDepthStencilSurface(IMtlDirect3DSurface9 **ppZStencilSurface) = 0;
    virtual MTL_HRESULT BeginScene() = 0;
    virtual MTL_HRESULT EndScene() = 0;
    virtual MTL_HRESULT Clear(uint32_t Count, const D3DMtlRect *pRects, uint32_t Flags, D3DCOLOR_T Color, float Z, uint32_t Stencil) = 0;
    virtual MTL_HRESULT SetTransform(uint32_t State, const float *pMatrix) = 0;
    virtual MTL_HRESULT GetTransform(uint32_t State, float *pMatrix) = 0;
    virtual MTL_HRESULT MultiplyTransform(uint32_t State, const float *pMatrix) = 0;
    virtual MTL_HRESULT SetViewport(const D3DMtlViewport *pViewport) = 0;
    virtual MTL_HRESULT GetViewport(D3DMtlViewport *pViewport) = 0;
    virtual MTL_HRESULT SetMaterial(const void *pMaterial) = 0;
    virtual MTL_HRESULT GetMaterial(void *pMaterial) = 0;
    virtual MTL_HRESULT SetLight(uint32_t Index, const void *pLight) = 0;
    virtual MTL_HRESULT GetLight(uint32_t Index, void *pLight) = 0;
    virtual MTL_HRESULT LightEnable(uint32_t Index, uint32_t Enable) = 0;
    virtual MTL_HRESULT GetLightEnable(uint32_t Index, uint32_t *pEnable) = 0;
    virtual MTL_HRESULT SetClipPlane(uint32_t Index, const float *pPlane) = 0;
    virtual MTL_HRESULT GetClipPlane(uint32_t Index, float *pPlane) = 0;
    virtual MTL_HRESULT SetRenderState(uint32_t State, uint32_t Value) = 0;
    virtual MTL_HRESULT GetRenderState(uint32_t State, uint32_t *pValue) = 0;
    virtual MTL_HRESULT CreateStateBlock(uint32_t Type, IMtlDirect3DStateBlock9 **ppSB) = 0;
    virtual MTL_HRESULT BeginStateBlock() = 0;
    virtual MTL_HRESULT EndStateBlock(IMtlDirect3DStateBlock9 **ppSB) = 0;
    virtual MTL_HRESULT SetClipStatus(const void *pClipStatus) = 0;
    virtual MTL_HRESULT GetClipStatus(void *pClipStatus) = 0;
    virtual MTL_HRESULT GetTexture(uint32_t Stage, IMtlDirect3DBaseTexture9 **ppTexture) = 0;
    virtual MTL_HRESULT SetTexture(uint32_t Stage, IMtlDirect3DBaseTexture9 *pTexture) = 0;
    virtual MTL_HRESULT GetTextureStageState(uint32_t Stage, uint32_t Type, uint32_t *pValue) = 0;
    virtual MTL_HRESULT SetTextureStageState(uint32_t Stage, uint32_t Type, uint32_t Value) = 0;
    virtual MTL_HRESULT GetSamplerState(uint32_t Sampler, uint32_t Type, uint32_t *pValue) = 0;
    virtual MTL_HRESULT SetSamplerState(uint32_t Sampler, uint32_t Type, uint32_t Value) = 0;
    virtual MTL_HRESULT ValidateDevice(uint32_t *pNumPasses) = 0;
    virtual MTL_HRESULT SetPaletteEntries(uint32_t PaletteNumber, const void *pEntries) = 0;
    virtual MTL_HRESULT GetPaletteEntries(uint32_t PaletteNumber, void *pEntries) = 0;
    virtual MTL_HRESULT SetCurrentTexturePalette(uint32_t PaletteNumber) = 0;
    virtual MTL_HRESULT GetCurrentTexturePalette(uint32_t *pPaletteNumber) = 0;
    virtual MTL_HRESULT SetScissorRect(const D3DMtlRect *pRect) = 0;
    virtual MTL_HRESULT GetScissorRect(D3DMtlRect *pRect) = 0;
    virtual MTL_HRESULT SetSoftwareVertexProcessing(uint32_t bSoftware) = 0;
    virtual uint32_t    GetSoftwareVertexProcessing() = 0;
    virtual MTL_HRESULT SetNPatchMode(float nSegments) = 0;
    virtual float       GetNPatchMode() = 0;
    virtual MTL_HRESULT DrawPrimitive(uint32_t PrimitiveType, uint32_t StartVertex, uint32_t PrimitiveCount) = 0;
    virtual MTL_HRESULT DrawIndexedPrimitive(uint32_t PrimitiveType, int32_t BaseVertexIndex, uint32_t MinVertexIndex, uint32_t NumVertices, uint32_t StartIndex, uint32_t PrimCount) = 0;
    virtual MTL_HRESULT DrawPrimitiveUP(uint32_t PrimitiveType, uint32_t PrimitiveCount, const void *pVertexStreamZeroData, uint32_t VertexStreamZeroStride) = 0;
    virtual MTL_HRESULT DrawIndexedPrimitiveUP(uint32_t PrimitiveType, uint32_t MinVertexIndex, uint32_t NumVertices, uint32_t PrimitiveCount, const void *pIndexData, uint32_t IndexDataFormat, const void *pVertexStreamZeroData, uint32_t VertexStreamZeroStride) = 0;
    virtual MTL_HRESULT ProcessVertices(uint32_t SrcStartIndex, uint32_t DestIndex, uint32_t VertexCount, IMtlDirect3DVertexBuffer9 *pDestBuffer, IMtlDirect3DVertexDeclaration9 *pVertexDecl, uint32_t Flags) = 0;
    virtual MTL_HRESULT CreateVertexDeclaration(const D3DMtlVertexElement *pVertexElements, IMtlDirect3DVertexDeclaration9 **ppDecl) = 0;
    virtual MTL_HRESULT SetVertexDeclaration(IMtlDirect3DVertexDeclaration9 *pDecl) = 0;
    virtual MTL_HRESULT GetVertexDeclaration(IMtlDirect3DVertexDeclaration9 **ppDecl) = 0;
    virtual MTL_HRESULT SetFVF(uint32_t FVF) = 0;
    virtual MTL_HRESULT GetFVF(uint32_t *pFVF) = 0;
    virtual MTL_HRESULT CreateVertexShader(const uint32_t *pFunction, IMtlDirect3DVertexShader9 **ppShader) = 0;
    virtual MTL_HRESULT SetVertexShader(IMtlDirect3DVertexShader9 *pShader) = 0;
    virtual MTL_HRESULT GetVertexShader(IMtlDirect3DVertexShader9 **ppShader) = 0;
    virtual MTL_HRESULT SetVertexShaderConstantF(uint32_t StartRegister, const float *pConstantData, uint32_t Vector4fCount) = 0;
    virtual MTL_HRESULT GetVertexShaderConstantF(uint32_t StartRegister, float *pConstantData, uint32_t Vector4fCount) = 0;
    virtual MTL_HRESULT SetVertexShaderConstantI(uint32_t StartRegister, const int32_t *pConstantData, uint32_t Vector4iCount) = 0;
    virtual MTL_HRESULT GetVertexShaderConstantI(uint32_t StartRegister, int32_t *pConstantData, uint32_t Vector4iCount) = 0;
    virtual MTL_HRESULT SetVertexShaderConstantB(uint32_t StartRegister, const uint32_t *pConstantData, uint32_t BoolCount) = 0;
    virtual MTL_HRESULT GetVertexShaderConstantB(uint32_t StartRegister, uint32_t *pConstantData, uint32_t BoolCount) = 0;
    virtual MTL_HRESULT SetStreamSource(uint32_t StreamNumber, IMtlDirect3DVertexBuffer9 *pStreamData, uint32_t OffsetInBytes, uint32_t Stride) = 0;
    virtual MTL_HRESULT GetStreamSource(uint32_t StreamNumber, IMtlDirect3DVertexBuffer9 **ppStreamData, uint32_t *pOffsetInBytes, uint32_t *pStride) = 0;
    virtual MTL_HRESULT SetStreamSourceFreq(uint32_t StreamNumber, uint32_t Setting) = 0;
    virtual MTL_HRESULT GetStreamSourceFreq(uint32_t StreamNumber, uint32_t *pSetting) = 0;
    virtual MTL_HRESULT SetIndices(IMtlDirect3DIndexBuffer9 *pIndexData) = 0;
    virtual MTL_HRESULT GetIndices(IMtlDirect3DIndexBuffer9 **ppIndexData) = 0;
    virtual MTL_HRESULT CreatePixelShader(const uint32_t *pFunction, IMtlDirect3DPixelShader9 **ppShader) = 0;
    virtual MTL_HRESULT SetPixelShader(IMtlDirect3DPixelShader9 *pShader) = 0;
    virtual MTL_HRESULT GetPixelShader(IMtlDirect3DPixelShader9 **ppShader) = 0;
    virtual MTL_HRESULT SetPixelShaderConstantF(uint32_t StartRegister, const float *pConstantData, uint32_t Vector4fCount) = 0;
    virtual MTL_HRESULT GetPixelShaderConstantF(uint32_t StartRegister, float *pConstantData, uint32_t Vector4fCount) = 0;
    virtual MTL_HRESULT SetPixelShaderConstantI(uint32_t StartRegister, const int32_t *pConstantData, uint32_t Vector4iCount) = 0;
    virtual MTL_HRESULT GetPixelShaderConstantI(uint32_t StartRegister, int32_t *pConstantData, uint32_t Vector4iCount) = 0;
    virtual MTL_HRESULT SetPixelShaderConstantB(uint32_t StartRegister, const uint32_t *pConstantData, uint32_t BoolCount) = 0;
    virtual MTL_HRESULT GetPixelShaderConstantB(uint32_t StartRegister, uint32_t *pConstantData, uint32_t BoolCount) = 0;
    virtual MTL_HRESULT DrawRectPatch(uint32_t Handle, const float *pNumSegs, const void *pRectPatchInfo) = 0;
    virtual MTL_HRESULT DrawTriPatch(uint32_t Handle, const float *pNumSegs, const void *pTriPatchInfo) = 0;
    virtual MTL_HRESULT DeletePatch(uint32_t Handle) = 0;
    virtual MTL_HRESULT CreateQuery(uint32_t Type, IMtlDirect3DQuery9 **ppQuery) = 0;
};

class IMtlDirect3DSwapChain9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT Present(const D3DMtlRect *pSourceRect, const D3DMtlRect *pDestRect, void *hDestWindowOverride, const void *pDirtyRegion, uint32_t dwFlags) = 0;
    virtual MTL_HRESULT GetFrontBufferData(IMtlDirect3DSurface9 *pDestSurface) = 0;
    virtual MTL_HRESULT GetBackBuffer(uint32_t iBackBuffer, uint32_t Type, IMtlDirect3DSurface9 **ppBackBuffer) = 0;
    virtual MTL_HRESULT GetRasterStatus(D3DMtlRasterStatus *pRasterStatus) = 0;
    virtual MTL_HRESULT GetDisplayMode(D3DMtlDisplayMode *pMode) = 0;
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT GetPresentParameters(D3DMtlPresentParameters *pPresentationParameters) = 0;
};

class IMtlDirect3DResource9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT SetPrivateData(const D3DMtlGuid *refguid, const void *pData, uint32_t SizeOfData, uint32_t Flags) = 0;
    virtual MTL_HRESULT GetPrivateData(const D3DMtlGuid *refguid, void *pData, uint32_t *pSizeOfData) = 0;
    virtual MTL_HRESULT FreePrivateData(const D3DMtlGuid *refguid) = 0;
    virtual uint32_t    SetPriority(uint32_t PriorityNew) = 0;
    virtual uint32_t    GetPriority() = 0;
    virtual void        PreLoad() = 0;
    virtual uint32_t    GetType() = 0;
};

class IMtlDirect3DSurface9 : public IMtlDirect3DResource9 {
public:
    virtual MTL_HRESULT GetContainer(const D3DMtlGuid *riid, void **ppContainer) = 0;
    virtual MTL_HRESULT GetDesc(D3DMtlSurfaceDesc *pDesc) = 0;
    virtual MTL_HRESULT LockRect(D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) = 0;
    virtual MTL_HRESULT UnlockRect() = 0;
    virtual MTL_HRESULT GetDC(void **phdc) = 0;
    virtual MTL_HRESULT ReleaseDC(void *hdc) = 0;
};

class IMtlDirect3DVolume9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT SetPrivateData(const D3DMtlGuid *refguid, const void *pData, uint32_t SizeOfData, uint32_t Flags) = 0;
    virtual MTL_HRESULT GetPrivateData(const D3DMtlGuid *refguid, void *pData, uint32_t *pSizeOfData) = 0;
    virtual MTL_HRESULT FreePrivateData(const D3DMtlGuid *refguid) = 0;
    virtual MTL_HRESULT GetContainer(const D3DMtlGuid *riid, void **ppContainer) = 0;
    virtual MTL_HRESULT GetDesc(D3DMtlVolumeDesc *pDesc) = 0;
    virtual MTL_HRESULT LockBox(D3DMtlLockedBox *pLockedVolume, const D3DMtlBox *pBox, uint32_t Flags) = 0;
    virtual MTL_HRESULT UnlockBox() = 0;
};

class IMtlDirect3DVertexBuffer9 : public IMtlDirect3DResource9 {
public:
    virtual MTL_HRESULT Lock(uint32_t OffsetToLock, uint32_t SizeToLock, void **ppbData, uint32_t Flags) = 0;
    virtual MTL_HRESULT Unlock() = 0;
    virtual MTL_HRESULT GetDesc(D3DMtlBufferDesc *pDesc) = 0;
};

class IMtlDirect3DIndexBuffer9 : public IMtlDirect3DResource9 {
public:
    virtual MTL_HRESULT Lock(uint32_t OffsetToLock, uint32_t SizeToLock, void **ppbData, uint32_t Flags) = 0;
    virtual MTL_HRESULT Unlock() = 0;
    virtual MTL_HRESULT GetDesc(D3DMtlBufferDesc *pDesc) = 0;
};

class IMtlDirect3DBaseTexture9 : public IMtlDirect3DResource9 {
public:
    virtual uint32_t    SetLOD(uint32_t LODNew) = 0;
    virtual uint32_t    GetLOD() = 0;
    virtual uint32_t    GetLevelCount() = 0;
    virtual MTL_HRESULT SetAutoGenFilterType(uint32_t FilterType) = 0;
    virtual uint32_t    GetAutoGenFilterType() = 0;
    virtual void        GenerateMipSubLevels() = 0;
};

class IMtlDirect3DTexture9 : public IMtlDirect3DBaseTexture9 {
public:
    virtual MTL_HRESULT GetLevelDesc(uint32_t Level, D3DMtlSurfaceDesc *pDesc) = 0;
    virtual MTL_HRESULT GetSurfaceLevel(uint32_t Level, IMtlDirect3DSurface9 **ppSurfaceLevel) = 0;
    virtual MTL_HRESULT LockRect(uint32_t Level, D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) = 0;
    virtual MTL_HRESULT UnlockRect(uint32_t Level) = 0;
    virtual MTL_HRESULT AddDirtyRect(const D3DMtlRect *pDirtyRect) = 0;
};

class IMtlDirect3DCubeTexture9 : public IMtlDirect3DBaseTexture9 {
public:
    virtual MTL_HRESULT GetLevelDesc(uint32_t Level, D3DMtlSurfaceDesc *pDesc) = 0;
    virtual MTL_HRESULT GetCubeMapSurface(uint32_t FaceType, uint32_t Level, IMtlDirect3DSurface9 **ppCubeMapSurface) = 0;
    virtual MTL_HRESULT LockRect(uint32_t FaceType, uint32_t Level, D3DMtlLockedRect *pLockedRect, const D3DMtlRect *pRect, uint32_t Flags) = 0;
    virtual MTL_HRESULT UnlockRect(uint32_t FaceType, uint32_t Level) = 0;
    virtual MTL_HRESULT AddDirtyRect(uint32_t FaceType, const D3DMtlRect *pDirtyRect) = 0;
};

class IMtlDirect3DVolumeTexture9 : public IMtlDirect3DBaseTexture9 {
public:
    virtual MTL_HRESULT GetLevelDesc(uint32_t Level, D3DMtlVolumeDesc *pDesc) = 0;
    virtual MTL_HRESULT GetVolumeLevel(uint32_t Level, IMtlDirect3DVolume9 **ppVolumeLevel) = 0;
    virtual MTL_HRESULT LockBox(uint32_t Level, D3DMtlLockedBox *pLockedVolume, const D3DMtlBox *pBox, uint32_t Flags) = 0;
    virtual MTL_HRESULT UnlockBox(uint32_t Level) = 0;
    virtual MTL_HRESULT AddDirtyBox(const D3DMtlBox *pDirtyBox) = 0;
};

class IMtlDirect3DVertexDeclaration9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT GetDeclaration(D3DMtlVertexElement *pElement, uint32_t *pNumElements) = 0;
};

class IMtlDirect3DVertexShader9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT GetFunction(void *pData, uint32_t *pSizeOfData) = 0;
};

class IMtlDirect3DPixelShader9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT GetFunction(void *pData, uint32_t *pSizeOfData) = 0;
};

class IMtlDirect3DStateBlock9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual MTL_HRESULT Capture() = 0;
    virtual MTL_HRESULT Apply() = 0;
};

class IMtlDirect3DQuery9 : public IMtlUnknown {
public:
    virtual MTL_HRESULT GetDevice(IMtlDirect3DDevice9 **ppDevice) = 0;
    virtual uint32_t    GetType() = 0;
    virtual uint32_t    GetDataSize() = 0;
    virtual MTL_HRESULT Issue(uint32_t dwIssueFlags) = 0;
    virtual MTL_HRESULT GetData(void *pData, uint32_t dwSize, uint32_t dwGetDataFlags) = 0;
};
