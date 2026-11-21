#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t  MTL_HRESULT;
typedef uint32_t D3D_BOOL;
typedef uint32_t D3D_DWORD;
typedef uint32_t D3D_UINT;
typedef int32_t  D3D_INT;
typedef uint32_t D3DCOLOR_T;

static constexpr MTL_HRESULT D3D_S_OK               = 0x00000000;
static constexpr MTL_HRESULT D3D_S_FALSE            = 0x00000001;
static constexpr MTL_HRESULT D3D_E_NOINTERFACE      = (MTL_HRESULT)0x80004002u;
static constexpr MTL_HRESULT D3D_E_FAIL             = (MTL_HRESULT)0x80004005u;
static constexpr MTL_HRESULT D3D_E_NOTIMPL          = (MTL_HRESULT)0x80004001u;
static constexpr MTL_HRESULT D3D_E_OUTOFMEMORY      = (MTL_HRESULT)0x8007000Eu;
static constexpr MTL_HRESULT D3D_ERR_INVALIDCALL    = (MTL_HRESULT)0x8876086Cu;
static constexpr MTL_HRESULT D3D_ERR_NOTAVAILABLE   = (MTL_HRESULT)0x8876086Au;
static constexpr MTL_HRESULT D3D_ERR_DEVICELOST     = (MTL_HRESULT)0x88760868u;
static constexpr MTL_HRESULT D3D_OK_NOAUTOGEN       = 0x08760873;

#define D3D_MAKEFOURCC(a, b, c, d) \
    ((uint32_t)(uint8_t)(a) | ((uint32_t)(uint8_t)(b) << 8) | \
     ((uint32_t)(uint8_t)(c) << 16) | ((uint32_t)(uint8_t)(d) << 24))

enum D3DMtlFormat : uint32_t {
    D3DM_FMT_UNKNOWN        = 0,
    D3DM_FMT_R8G8B8         = 20,
    D3DM_FMT_A8R8G8B8       = 21,
    D3DM_FMT_X8R8G8B8       = 22,
    D3DM_FMT_R5G6B5         = 23,
    D3DM_FMT_X1R5G5B5       = 24,
    D3DM_FMT_A1R5G5B5       = 25,
    D3DM_FMT_A4R4G4B4       = 26,
    D3DM_FMT_A8             = 28,
    D3DM_FMT_A2B10G10R10    = 31,
    D3DM_FMT_A8B8G8R8       = 32,
    D3DM_FMT_X8B8G8R8       = 33,
    D3DM_FMT_G16R16         = 34,
    D3DM_FMT_A2R10G10B10    = 35,
    D3DM_FMT_A16B16G16R16   = 36,
    D3DM_FMT_L8             = 50,
    D3DM_FMT_A8L8           = 51,
    D3DM_FMT_V8U8           = 60,
    D3DM_FMT_Q8W8V8U8       = 63,
    D3DM_FMT_V16U16         = 64,
    D3DM_FMT_D16_LOCKABLE   = 70,
    D3DM_FMT_D32            = 71,
    D3DM_FMT_D15S1          = 73,
    D3DM_FMT_D24S8          = 75,
    D3DM_FMT_D24X8          = 77,
    D3DM_FMT_D24X4S4        = 79,
    D3DM_FMT_D16            = 80,
    D3DM_FMT_D32F_LOCKABLE  = 82,
    D3DM_FMT_D24FS8         = 83,
    D3DM_FMT_L16            = 81,
    D3DM_FMT_VERTEXDATA     = 100,
    D3DM_FMT_INDEX16        = 101,
    D3DM_FMT_INDEX32        = 102,
    D3DM_FMT_Q16W16V16U16   = 110,
    D3DM_FMT_R16F           = 111,
    D3DM_FMT_G16R16F        = 112,
    D3DM_FMT_A16B16G16R16F  = 113,
    D3DM_FMT_R32F           = 114,
    D3DM_FMT_G32R32F        = 115,
    D3DM_FMT_A32B32G32R32F  = 116,
    D3DM_FMT_DXT1           = D3D_MAKEFOURCC('D', 'X', 'T', '1'),
    D3DM_FMT_DXT2           = D3D_MAKEFOURCC('D', 'X', 'T', '2'),
    D3DM_FMT_DXT3           = D3D_MAKEFOURCC('D', 'X', 'T', '3'),
    D3DM_FMT_DXT4           = D3D_MAKEFOURCC('D', 'X', 'T', '4'),
    D3DM_FMT_DXT5           = D3D_MAKEFOURCC('D', 'X', 'T', '5'),
    D3DM_FMT_ATI1           = D3D_MAKEFOURCC('A', 'T', 'I', '1'),
    D3DM_FMT_ATI2           = D3D_MAKEFOURCC('A', 'T', 'I', '2'),
    D3DM_FMT_INTZ           = D3D_MAKEFOURCC('I', 'N', 'T', 'Z'),
    D3DM_FMT_DF16           = D3D_MAKEFOURCC('D', 'F', '1', '6'),
    D3DM_FMT_DF24           = D3D_MAKEFOURCC('D', 'F', '2', '4'),
    D3DM_FMT_NULL           = D3D_MAKEFOURCC('N', 'U', 'L', 'L'),
};

enum D3DMtlResourceType : uint32_t {
    D3DM_RTYPE_SURFACE       = 1,
    D3DM_RTYPE_VOLUME        = 2,
    D3DM_RTYPE_TEXTURE       = 3,
    D3DM_RTYPE_VOLUMETEXTURE = 4,
    D3DM_RTYPE_CUBETEXTURE   = 5,
    D3DM_RTYPE_VERTEXBUFFER  = 6,
    D3DM_RTYPE_INDEXBUFFER   = 7,
};

enum D3DMtlPool : uint32_t {
    D3DM_POOL_DEFAULT   = 0,
    D3DM_POOL_MANAGED   = 1,
    D3DM_POOL_SYSTEMMEM = 2,
    D3DM_POOL_SCRATCH   = 3,
};

enum D3DMtlUsage : uint32_t {
    D3DM_USAGE_RENDERTARGET                 = 0x00000001u,
    D3DM_USAGE_DEPTHSTENCIL                 = 0x00000002u,
    D3DM_USAGE_WRITEONLY                    = 0x00000008u,
    D3DM_USAGE_SOFTWAREPROCESSING           = 0x00000010u,
    D3DM_USAGE_DONOTCLIP                    = 0x00000020u,
    D3DM_USAGE_POINTS                       = 0x00000040u,
    D3DM_USAGE_RTPATCHES                    = 0x00000080u,
    D3DM_USAGE_NPATCHES                     = 0x00000100u,
    D3DM_USAGE_DYNAMIC                      = 0x00000200u,
    D3DM_USAGE_AUTOGENMIPMAP                = 0x00000400u,
    D3DM_USAGE_QUERY_SRGBREAD               = 0x00010000u,
    D3DM_USAGE_QUERY_FILTER                 = 0x00020000u,
    D3DM_USAGE_QUERY_SRGBWRITE              = 0x00040000u,
    D3DM_USAGE_QUERY_POSTPIXELSHADER_BLEND  = 0x00080000u,
    D3DM_USAGE_QUERY_VERTEXTEXTURE          = 0x00100000u,
    D3DM_USAGE_QUERY_WRAPANDMIP             = 0x00200000u,
};

enum D3DMtlLockFlags : uint32_t {
    D3DM_LOCK_READONLY      = 0x00000010u,
    D3DM_LOCK_DISCARD       = 0x00002000u,
    D3DM_LOCK_NOOVERWRITE   = 0x00001000u,
    D3DM_LOCK_NOSYSLOCK     = 0x00000800u,
    D3DM_LOCK_DONOTWAIT     = 0x00004000u,
    D3DM_LOCK_NO_DIRTY_UP   = 0x00008000u,
};

enum D3DMtlClearFlags : uint32_t {
    D3DM_CLEAR_TARGET  = 0x00000001u,
    D3DM_CLEAR_ZBUFFER = 0x00000002u,
    D3DM_CLEAR_STENCIL = 0x00000004u,
};

enum D3DMtlPrimType : uint32_t {
    D3DM_PT_POINTLIST     = 1,
    D3DM_PT_LINELIST      = 2,
    D3DM_PT_LINESTRIP     = 3,
    D3DM_PT_TRIANGLELIST  = 4,
    D3DM_PT_TRIANGLESTRIP = 5,
    D3DM_PT_TRIANGLEFAN   = 6,
};

enum D3DMtlQueryType : uint32_t {
    D3DM_QUERYTYPE_EVENT     = 8,
    D3DM_QUERYTYPE_OCCLUSION = 9,
};

typedef struct D3DMtlGuid {
    uint32_t Data1;
    uint16_t Data2;
    uint16_t Data3;
    uint8_t  Data4[8];
} D3DMtlGuid;

typedef struct D3DMtlRect {
    int32_t left;
    int32_t top;
    int32_t right;
    int32_t bottom;
} D3DMtlRect;

typedef struct D3DMtlBox {
    uint32_t Left;
    uint32_t Top;
    uint32_t Right;
    uint32_t Bottom;
    uint32_t Front;
    uint32_t Back;
} D3DMtlBox;

typedef struct D3DMtlPoint {
    int32_t x;
    int32_t y;
} D3DMtlPoint;

typedef struct D3DMtlViewport {
    uint32_t X;
    uint32_t Y;
    uint32_t Width;
    uint32_t Height;
    float    MinZ;
    float    MaxZ;
} D3DMtlViewport;

typedef struct D3DMtlDisplayMode {
    uint32_t Width;
    uint32_t Height;
    uint32_t RefreshRate;
    uint32_t Format;
} D3DMtlDisplayMode;

/* Matches HostPresent in rt_d3d9.c (LP64 pointer-wide HWND) */
typedef struct D3DMtlPresentParameters {
    uint32_t BackBufferWidth;
    uint32_t BackBufferHeight;
    uint32_t BackBufferFormat;
    uint32_t BackBufferCount;
    uint32_t MultiSampleType;
    uint32_t MultiSampleQuality;
    uint32_t SwapEffect;
    void    *hDeviceWindow;
    uint32_t Windowed;
    uint32_t EnableAutoDepthStencil;
    uint32_t AutoDepthStencilFormat;
    uint32_t Flags;
    uint32_t FullScreen_RefreshRateInHz;
    uint32_t PresentationInterval;
} D3DMtlPresentParameters;

/* Matches rt_d3d9.c GetCreationParameters (LP64 pointer-wide HWND) */
typedef struct D3DMtlCreationParameters {
    uint32_t AdapterOrdinal;
    uint32_t DeviceType;
    void    *hFocusWindow;
    uint32_t BehaviorFlags;
} D3DMtlCreationParameters;

typedef struct D3DMtlAdapterIdentifier {
    char     Driver[512];
    char     Description[512];
    char     DeviceName[32];
    uint64_t DriverVersion;
    uint32_t VendorId;
    uint32_t DeviceId;
    uint32_t SubSysId;
    uint32_t Revision;
    D3DMtlGuid DeviceIdentifier;
    uint32_t WHQLLevel;
} D3DMtlAdapterIdentifier;

typedef struct D3DMtlSurfaceDesc {
    uint32_t Format;
    uint32_t Type;
    uint32_t Usage;
    uint32_t Pool;
    uint32_t MultiSampleType;
    uint32_t MultiSampleQuality;
    uint32_t Width;
    uint32_t Height;
} D3DMtlSurfaceDesc;

typedef struct D3DMtlVolumeDesc {
    uint32_t Format;
    uint32_t Type;
    uint32_t Usage;
    uint32_t Pool;
    uint32_t Width;
    uint32_t Height;
    uint32_t Depth;
} D3DMtlVolumeDesc;

typedef struct D3DMtlBufferDesc {
    uint32_t Format;
    uint32_t Type;
    uint32_t Usage;
    uint32_t Pool;
    uint32_t Size;
    uint32_t FVF;
} D3DMtlBufferDesc;

typedef struct D3DMtlLockedRect {
    int32_t Pitch;
    void   *pBits;
} D3DMtlLockedRect;

typedef struct D3DMtlLockedBox {
    int32_t RowPitch;
    int32_t SlicePitch;
    void   *pBits;
} D3DMtlLockedBox;

typedef struct D3DMtlVertexElement {
    uint16_t Stream;
    uint16_t Offset;
    uint8_t  Type;
    uint8_t  Method;
    uint8_t  Usage;
    uint8_t  UsageIndex;
} D3DMtlVertexElement;

typedef struct D3DMtlShaderCaps2_0 {
    uint32_t Caps;
    int32_t  DynamicFlowControlDepth;
    int32_t  NumTemps;
    int32_t  StaticFlowControlDepth;
} D3DMtlShaderCaps2_0;

typedef struct D3DMtlShaderCaps2_0_PS {
    uint32_t Caps;
    int32_t  DynamicFlowControlDepth;
    int32_t  NumTemps;
    int32_t  StaticFlowControlDepth;
    int32_t  NumInstructionSlots;
} D3DMtlShaderCaps2_0_PS;

typedef struct D3DMtlCaps9 {
    uint32_t DeviceType;
    uint32_t AdapterOrdinal;
    uint32_t Caps;
    uint32_t Caps2;
    uint32_t Caps3;
    uint32_t PresentationIntervals;
    uint32_t CursorCaps;
    uint32_t DevCaps;
    uint32_t PrimitiveMiscCaps;
    uint32_t RasterCaps;
    uint32_t ZCmpCaps;
    uint32_t SrcBlendCaps;
    uint32_t DestBlendCaps;
    uint32_t AlphaCmpCaps;
    uint32_t ShadeCaps;
    uint32_t TextureCaps;
    uint32_t TextureFilterCaps;
    uint32_t CubeTextureFilterCaps;
    uint32_t VolumeTextureFilterCaps;
    uint32_t TextureAddressCaps;
    uint32_t VolumeTextureAddressCaps;
    uint32_t LineCaps;
    uint32_t MaxTextureWidth;
    uint32_t MaxTextureHeight;
    uint32_t MaxVolumeExtent;
    uint32_t MaxTextureRepeat;
    uint32_t MaxTextureAspectRatio;
    uint32_t MaxAnisotropy;
    float    MaxVertexW;
    float    GuardBandLeft;
    float    GuardBandTop;
    float    GuardBandRight;
    float    GuardBandBottom;
    float    ExtentsAdjust;
    uint32_t StencilCaps;
    uint32_t FVFCaps;
    uint32_t TextureOpCaps;
    uint32_t MaxTextureBlendStages;
    uint32_t MaxSimultaneousTextures;
    uint32_t VertexProcessingCaps;
    uint32_t MaxActiveLights;
    uint32_t MaxUserClipPlanes;
    uint32_t MaxVertexBlendMatrices;
    uint32_t MaxVertexBlendMatrixIndex;
    float    MaxPointSize;
    uint32_t MaxPrimitiveCount;
    uint32_t MaxVertexIndex;
    uint32_t MaxStreams;
    uint32_t MaxStreamStride;
    uint32_t VertexShaderVersion;
    uint32_t MaxVertexShaderConst;
    uint32_t PixelShaderVersion;
    float    PixelShader1xMaxValue;
    uint32_t DevCaps2;
    float    MaxNpatchTessellationLevel;
    uint32_t Reserved5;
    uint32_t MasterAdapterOrdinal;
    uint32_t AdapterOrdinalInGroup;
    uint32_t NumberOfAdaptersInGroup;
    uint32_t DeclTypes;
    uint32_t NumSimultaneousRTs;
    uint32_t StretchRectFilterCaps;
    D3DMtlShaderCaps2_0 VS20Caps;
    D3DMtlShaderCaps2_0_PS PS20Caps;
    uint32_t VertexTextureFilterCaps;
    uint32_t MaxVShaderInstructionsExecuted;
    uint32_t MaxPShaderInstructionsExecuted;
    uint32_t MaxVertexShader30InstructionSlots;
    uint32_t MaxPixelShader30InstructionSlots;
} D3DMtlCaps9;

#ifdef __cplusplus
static_assert(sizeof(D3DMtlCaps9) == 304, "D3DMtlCaps9 must match D3DCAPS9 (304 bytes)");
static_assert(offsetof(D3DMtlAdapterIdentifier, WHQLLevel) == 1096, "D3DMtlAdapterIdentifier layout");
#endif

typedef struct D3DMtlRasterStatus {
    uint32_t InVBlank;
    uint32_t ScanLine;
} D3DMtlRasterStatus;

typedef struct D3DMtlGammaRamp {
    uint16_t red[256];
    uint16_t green[256];
    uint16_t blue[256];
} D3DMtlGammaRamp;

#ifdef __cplusplus
}
#endif
