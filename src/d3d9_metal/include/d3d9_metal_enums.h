#pragma once

#include <stdint.h>

enum D3DMtlRenderState : uint32_t {
    D3DM_RS_ZENABLE                  = 7,
    D3DM_RS_FILLMODE                 = 8,
    D3DM_RS_SHADEMODE                = 9,
    D3DM_RS_ZWRITEENABLE             = 14,
    D3DM_RS_ALPHATESTENABLE          = 15,
    D3DM_RS_SRCBLEND                 = 19,
    D3DM_RS_DESTBLEND                = 20,
    D3DM_RS_CULLMODE                 = 22,
    D3DM_RS_ZFUNC                    = 23,
    D3DM_RS_ALPHAREF                 = 24,
    D3DM_RS_ALPHAFUNC                = 25,
    D3DM_RS_ALPHABLENDENABLE         = 27,
    D3DM_RS_FOGENABLE                = 28,
    D3DM_RS_FOGCOLOR                 = 34,
    D3DM_RS_FOGTABLEMODE             = 35,
    D3DM_RS_FOGSTART                 = 36,
    D3DM_RS_FOGEND                   = 37,
    D3DM_RS_FOGDENSITY               = 38,
    D3DM_RS_STENCILENABLE            = 52,
    D3DM_RS_STENCILFAIL              = 53,
    D3DM_RS_STENCILZFAIL             = 54,
    D3DM_RS_STENCILPASS              = 55,
    D3DM_RS_STENCILFUNC              = 56,
    D3DM_RS_STENCILREF               = 57,
    D3DM_RS_STENCILMASK              = 58,
    D3DM_RS_STENCILWRITEMASK         = 59,
    D3DM_RS_CLIPPING                 = 136,
    D3DM_RS_CLIPPLANEENABLE          = 152,
    D3DM_RS_POINTSIZE                = 154,
    D3DM_RS_POINTSIZE_MIN            = 155,
    D3DM_RS_POINTSPRITEENABLE        = 156,
    D3DM_RS_POINTSIZE_MAX            = 166,
    D3DM_RS_COLORWRITEENABLE         = 168,
    D3DM_RS_BLENDOP                  = 171,
    D3DM_RS_SCISSORTESTENABLE        = 174,
    D3DM_RS_SLOPESCALEDEPTHBIAS      = 175,
    D3DM_RS_TWOSIDEDSTENCILMODE      = 185,
    D3DM_RS_CCW_STENCILFAIL          = 186,
    D3DM_RS_CCW_STENCILZFAIL         = 187,
    D3DM_RS_CCW_STENCILPASS          = 188,
    D3DM_RS_CCW_STENCILFUNC          = 189,
    D3DM_RS_COLORWRITEENABLE1        = 190,
    D3DM_RS_COLORWRITEENABLE2        = 191,
    D3DM_RS_COLORWRITEENABLE3        = 192,
    D3DM_RS_BLENDFACTOR              = 193,
    D3DM_RS_SRGBWRITEENABLE          = 194,
    D3DM_RS_DEPTHBIAS                = 195,
    D3DM_RS_SEPARATEALPHABLENDENABLE = 206,
    D3DM_RS_SRCBLENDALPHA            = 207,
    D3DM_RS_DESTBLENDALPHA           = 208,
    D3DM_RS_BLENDOPALPHA             = 209,
    D3DM_RS_ADAPTIVETESS_Y           = 181,
    D3DM_RS_MAX                      = 212,
};

enum D3DMtlSamplerState : uint32_t {
    D3DM_SAMP_ADDRESSU      = 1,
    D3DM_SAMP_ADDRESSV      = 2,
    D3DM_SAMP_ADDRESSW      = 3,
    D3DM_SAMP_BORDERCOLOR   = 4,
    D3DM_SAMP_MAGFILTER     = 5,
    D3DM_SAMP_MINFILTER     = 6,
    D3DM_SAMP_MIPFILTER     = 7,
    D3DM_SAMP_MIPMAPLODBIAS = 8,
    D3DM_SAMP_MAXMIPLEVEL   = 9,
    D3DM_SAMP_MAXANISOTROPY = 10,
    D3DM_SAMP_SRGBTEXTURE   = 11,
    D3DM_SAMP_MAX           = 16,
};

enum D3DMtlTexAddress : uint32_t {
    D3DM_TADDRESS_WRAP       = 1,
    D3DM_TADDRESS_MIRROR     = 2,
    D3DM_TADDRESS_CLAMP      = 3,
    D3DM_TADDRESS_BORDER     = 4,
    D3DM_TADDRESS_MIRRORONCE = 5,
};

enum D3DMtlTexFilter : uint32_t {
    D3DM_TEXF_NONE        = 0,
    D3DM_TEXF_POINT       = 1,
    D3DM_TEXF_LINEAR      = 2,
    D3DM_TEXF_ANISOTROPIC = 3,
};

enum D3DMtlBlend : uint32_t {
    D3DM_BLEND_ZERO            = 1,
    D3DM_BLEND_ONE             = 2,
    D3DM_BLEND_SRCCOLOR        = 3,
    D3DM_BLEND_INVSRCCOLOR     = 4,
    D3DM_BLEND_SRCALPHA        = 5,
    D3DM_BLEND_INVSRCALPHA     = 6,
    D3DM_BLEND_DESTALPHA       = 7,
    D3DM_BLEND_INVDESTALPHA    = 8,
    D3DM_BLEND_DESTCOLOR       = 9,
    D3DM_BLEND_INVDESTCOLOR    = 10,
    D3DM_BLEND_SRCALPHASAT     = 11,
    D3DM_BLEND_BOTHSRCALPHA    = 12,
    D3DM_BLEND_BOTHINVSRCALPHA = 13,
    D3DM_BLEND_BLENDFACTOR     = 14,
    D3DM_BLEND_INVBLENDFACTOR  = 15,
};

enum D3DMtlBlendOp : uint32_t {
    D3DM_BLENDOP_ADD         = 1,
    D3DM_BLENDOP_SUBTRACT    = 2,
    D3DM_BLENDOP_REVSUBTRACT = 3,
    D3DM_BLENDOP_MIN         = 4,
    D3DM_BLENDOP_MAX         = 5,
};

enum D3DMtlCmpFunc : uint32_t {
    D3DM_CMP_NEVER        = 1,
    D3DM_CMP_LESS         = 2,
    D3DM_CMP_EQUAL        = 3,
    D3DM_CMP_LESSEQUAL    = 4,
    D3DM_CMP_GREATER      = 5,
    D3DM_CMP_NOTEQUAL     = 6,
    D3DM_CMP_GREATEREQUAL = 7,
    D3DM_CMP_ALWAYS       = 8,
};

enum D3DMtlCull : uint32_t {
    D3DM_CULL_NONE = 1,
    D3DM_CULL_CW   = 2,
    D3DM_CULL_CCW  = 3,
};

enum D3DMtlFillMode : uint32_t {
    D3DM_FILL_POINT     = 1,
    D3DM_FILL_WIREFRAME = 2,
    D3DM_FILL_SOLID     = 3,
};

enum D3DMtlStencilOp : uint32_t {
    D3DM_STENCILOP_KEEP    = 1,
    D3DM_STENCILOP_ZERO    = 2,
    D3DM_STENCILOP_REPLACE = 3,
    D3DM_STENCILOP_INCRSAT = 4,
    D3DM_STENCILOP_DECRSAT = 5,
    D3DM_STENCILOP_INVERT  = 6,
    D3DM_STENCILOP_INCR    = 7,
    D3DM_STENCILOP_DECR    = 8,
};

enum D3DMtlDeclType : uint8_t {
    D3DM_DECLTYPE_FLOAT1    = 0,
    D3DM_DECLTYPE_FLOAT2    = 1,
    D3DM_DECLTYPE_FLOAT3    = 2,
    D3DM_DECLTYPE_FLOAT4    = 3,
    D3DM_DECLTYPE_D3DCOLOR  = 4,
    D3DM_DECLTYPE_UBYTE4    = 5,
    D3DM_DECLTYPE_SHORT2    = 6,
    D3DM_DECLTYPE_SHORT4    = 7,
    D3DM_DECLTYPE_UBYTE4N   = 8,
    D3DM_DECLTYPE_SHORT2N   = 9,
    D3DM_DECLTYPE_SHORT4N   = 10,
    D3DM_DECLTYPE_USHORT2N  = 11,
    D3DM_DECLTYPE_USHORT4N  = 12,
    D3DM_DECLTYPE_UDEC3     = 13,
    D3DM_DECLTYPE_DEC3N     = 14,
    D3DM_DECLTYPE_FLOAT16_2 = 15,
    D3DM_DECLTYPE_FLOAT16_4 = 16,
    D3DM_DECLTYPE_UNUSED    = 17,
};

static constexpr uint32_t D3DM_STREAMSOURCE_INDEXEDDATA  = (1u << 30);
static constexpr uint32_t D3DM_STREAMSOURCE_INSTANCEDATA = (2u << 30);
static constexpr uint32_t D3DM_ISSUE_END                 = (1u << 0);
static constexpr uint32_t D3DM_ISSUE_BEGIN               = (1u << 1);
static constexpr uint32_t D3DM_GETDATA_FLUSH             = (1u << 0);
static constexpr uint32_t D3DM_PRESENT_INTERVAL_IMMEDIATE = 0x80000000u;
static constexpr uint32_t D3DM_VERTEXTEXTURESAMPLER0     = 257u;
