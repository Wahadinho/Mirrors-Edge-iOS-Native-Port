#include "mtl_format.h"
#include <algorithm>

namespace mtl_d3d9 {

MtlFormatInfo mapD3dFormat(uint32_t fmt) {
    MtlFormatInfo info = {};
    switch (fmt) {
        case D3DM_FMT_A8R8G8B8:
            info.pixelFormat = MTLPixelFormatBGRA8Unorm;
            info.srgbPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = true;
            break;
        case D3DM_FMT_X8R8G8B8:
            info.pixelFormat = MTLPixelFormatBGRA8Unorm;
            info.srgbPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A8B8G8R8:
            info.pixelFormat = MTLPixelFormatRGBA8Unorm;
            info.srgbPixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = true;
            break;
        case D3DM_FMT_X8B8G8R8:
            info.pixelFormat = MTLPixelFormatRGBA8Unorm;
            info.srgbPixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_R5G6B5:
            info.pixelFormat = MTLPixelFormatB5G6R5Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = false;
            break;
        case D3DM_FMT_A1R5G5B5:
            info.pixelFormat = MTLPixelFormatBGR5A1Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = true;
            break;
        case D3DM_FMT_X1R5G5B5:
            info.pixelFormat = MTLPixelFormatBGR5A1Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A4R4G4B4:
            info.pixelFormat = MTLPixelFormatABGR4Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha, MTLTextureSwizzleRed };
            break;
        case D3DM_FMT_A8:
            info.pixelFormat = MTLPixelFormatA8Unorm;
            info.bytesPerPixel = 1; info.blockBytes = 1; info.hasAlpha = true;
            break;
        case D3DM_FMT_L8:
            info.pixelFormat = MTLPixelFormatR8Unorm;
            info.bytesPerPixel = 1; info.blockBytes = 1; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A8L8:
            info.pixelFormat = MTLPixelFormatRG8Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleGreen };
            break;
        case D3DM_FMT_L16:
            info.pixelFormat = MTLPixelFormatR16Unorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_V8U8:
            info.pixelFormat = MTLPixelFormatRG8Snorm;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_Q8W8V8U8:
            info.pixelFormat = MTLPixelFormatRGBA8Snorm;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = true;
            break;
        case D3DM_FMT_V16U16:
            info.pixelFormat = MTLPixelFormatRG16Snorm;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_Q16W16V16U16:
            info.pixelFormat = MTLPixelFormatRGBA16Snorm;
            info.bytesPerPixel = 8; info.blockBytes = 8; info.hasAlpha = true;
            break;
        case D3DM_FMT_G16R16:
            info.pixelFormat = MTLPixelFormatRG16Unorm;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = false;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A2R10G10B10:
            info.pixelFormat = MTLPixelFormatBGR10A2Unorm;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = true;
            break;
        case D3DM_FMT_A2B10G10R10:
            info.pixelFormat = MTLPixelFormatRGB10A2Unorm;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.hasAlpha = true;
            break;
        case D3DM_FMT_A16B16G16R16:
            info.pixelFormat = MTLPixelFormatRGBA16Unorm;
            info.bytesPerPixel = 8; info.blockBytes = 8; info.hasAlpha = true;
            break;
        case D3DM_FMT_R16F:
            info.pixelFormat = MTLPixelFormatR16Float;
            info.bytesPerPixel = 2; info.blockBytes = 2; info.isFloat = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_G16R16F:
            info.pixelFormat = MTLPixelFormatRG16Float;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isFloat = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A16B16G16R16F:
            info.pixelFormat = MTLPixelFormatRGBA16Float;
            info.bytesPerPixel = 8; info.blockBytes = 8; info.hasAlpha = true; info.isFloat = true;
            break;
        case D3DM_FMT_R32F:
            info.pixelFormat = MTLPixelFormatR32Float;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isFloat = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_G32R32F:
            info.pixelFormat = MTLPixelFormatRG32Float;
            info.bytesPerPixel = 8; info.blockBytes = 8; info.isFloat = true;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_A32B32G32R32F:
            info.pixelFormat = MTLPixelFormatRGBA32Float;
            info.bytesPerPixel = 16; info.blockBytes = 16; info.hasAlpha = true; info.isFloat = true;
            break;
        case D3DM_FMT_DXT1:
            info.pixelFormat = MTLPixelFormatBC1_RGBA;
            info.srgbPixelFormat = MTLPixelFormatBC1_RGBA_sRGB;
            info.blockWidth = 4; info.blockHeight = 4; info.blockBytes = 8; info.hasAlpha = true;
            break;
        case D3DM_FMT_DXT2:
        case D3DM_FMT_DXT3:
            info.pixelFormat = MTLPixelFormatBC2_RGBA;
            info.srgbPixelFormat = MTLPixelFormatBC2_RGBA_sRGB;
            info.blockWidth = 4; info.blockHeight = 4; info.blockBytes = 16; info.hasAlpha = true;
            break;
        case D3DM_FMT_DXT4:
        case D3DM_FMT_DXT5:
            info.pixelFormat = MTLPixelFormatBC3_RGBA;
            info.srgbPixelFormat = MTLPixelFormatBC3_RGBA_sRGB;
            info.blockWidth = 4; info.blockHeight = 4; info.blockBytes = 16; info.hasAlpha = true;
            break;
        case D3DM_FMT_ATI1:
            info.pixelFormat = MTLPixelFormatBC4_RUnorm;
            info.blockWidth = 4; info.blockHeight = 4; info.blockBytes = 8;
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_ATI2:
            info.pixelFormat = MTLPixelFormatBC5_RGUnorm;
            info.blockWidth = 4; info.blockHeight = 4; info.blockBytes = 16;
            /* D3D9 3Dc/ATI2 stores Y in block 0 (G) and X in block 1 (R); unused B/A read as 1.0 */
            info.hasSwizzle = true;
            info.swizzle = { MTLTextureSwizzleGreen, MTLTextureSwizzleRed, MTLTextureSwizzleOne, MTLTextureSwizzleOne };
            break;
        case D3DM_FMT_D16:
        case D3DM_FMT_D16_LOCKABLE:
        case D3DM_FMT_D32:
        case D3DM_FMT_D32F_LOCKABLE:
        case D3DM_FMT_D24X8:
            info.pixelFormat = MTLPixelFormatDepth32Float;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isDepth = true;
            break;
        case D3DM_FMT_DF16:
        case D3DM_FMT_DF24:
            info.pixelFormat = MTLPixelFormatDepth32Float;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isDepth = true; info.isRawDepthFetch = true;
            break;
        case D3DM_FMT_D24S8:
        case D3DM_FMT_D24FS8:
        case D3DM_FMT_D24X4S4:
        case D3DM_FMT_D15S1:
            info.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isDepth = true; info.hasStencil = true;
            break;
        case D3DM_FMT_INTZ:
            info.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            info.bytesPerPixel = 4; info.blockBytes = 4; info.isDepth = true; info.hasStencil = true; info.isRawDepthFetch = true;
            break;
        case D3DM_FMT_NULL:
            info.pixelFormat = MTLPixelFormatInvalid;
            info.isNullFormat = true;
            break;
        default:
            break;
    }
    return info;
}

uint32_t calcRowPitch(uint32_t d3dFormat, uint32_t width) {
    MtlFormatInfo fi = mapD3dFormat(d3dFormat);
    if (fi.blockBytes == 0) return width * 4u;
    uint32_t blocksX = (std::max(width, 1u) + fi.blockWidth - 1u) / fi.blockWidth;
    return blocksX * fi.blockBytes;
}

uint32_t calcRowCount(uint32_t d3dFormat, uint32_t height) {
    MtlFormatInfo fi = mapD3dFormat(d3dFormat);
    return (std::max(height, 1u) + fi.blockHeight - 1u) / fi.blockHeight;
}

uint32_t calcSliceSize(uint32_t d3dFormat, uint32_t width, uint32_t height) {
    return calcRowPitch(d3dFormat, width) * calcRowCount(d3dFormat, height);
}

MTLVertexFormat mapD3dDeclType(uint8_t t) {
    switch (t) {
        case D3DM_DECLTYPE_FLOAT1:    return MTLVertexFormatFloat;
        case D3DM_DECLTYPE_FLOAT2:    return MTLVertexFormatFloat2;
        case D3DM_DECLTYPE_FLOAT3:    return MTLVertexFormatFloat3;
        case D3DM_DECLTYPE_FLOAT4:    return MTLVertexFormatFloat4;
        case D3DM_DECLTYPE_D3DCOLOR:  return MTLVertexFormatUChar4Normalized_BGRA;
        case D3DM_DECLTYPE_UBYTE4:    return MTLVertexFormatUChar4;
        case D3DM_DECLTYPE_SHORT2:    return MTLVertexFormatShort2;
        case D3DM_DECLTYPE_SHORT4:    return MTLVertexFormatShort4;
        case D3DM_DECLTYPE_UBYTE4N:   return MTLVertexFormatUChar4Normalized;
        case D3DM_DECLTYPE_SHORT2N:   return MTLVertexFormatShort2Normalized;
        case D3DM_DECLTYPE_SHORT4N:   return MTLVertexFormatShort4Normalized;
        case D3DM_DECLTYPE_USHORT2N:  return MTLVertexFormatUShort2Normalized;
        case D3DM_DECLTYPE_USHORT4N:  return MTLVertexFormatUShort4Normalized;
        case D3DM_DECLTYPE_UDEC3:     return MTLVertexFormatUInt1010102Normalized;
        case D3DM_DECLTYPE_DEC3N:     return MTLVertexFormatInt1010102Normalized;
        case D3DM_DECLTYPE_FLOAT16_2: return MTLVertexFormatHalf2;
        case D3DM_DECLTYPE_FLOAT16_4: return MTLVertexFormatHalf4;
        default:                      return MTLVertexFormatFloat4;
    }
}

MTLBlendFactor mapD3dBlendFactor(uint32_t blend, bool targetHasAlpha) {
    switch (blend) {
        case D3DM_BLEND_ZERO:           return MTLBlendFactorZero;
        case D3DM_BLEND_ONE:            return MTLBlendFactorOne;
        case D3DM_BLEND_SRCCOLOR:       return MTLBlendFactorSourceColor;
        case D3DM_BLEND_INVSRCCOLOR:    return MTLBlendFactorOneMinusSourceColor;
        case D3DM_BLEND_SRCALPHA:       return MTLBlendFactorSourceAlpha;
        case D3DM_BLEND_INVSRCALPHA:    return MTLBlendFactorOneMinusSourceAlpha;
        case D3DM_BLEND_DESTALPHA:      return targetHasAlpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorOne;
        case D3DM_BLEND_INVDESTALPHA:   return targetHasAlpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorZero;
        case D3DM_BLEND_DESTCOLOR:      return MTLBlendFactorDestinationColor;
        case D3DM_BLEND_INVDESTCOLOR:   return MTLBlendFactorOneMinusDestinationColor;
        case D3DM_BLEND_SRCALPHASAT:    return MTLBlendFactorSourceAlphaSaturated;
        case D3DM_BLEND_BLENDFACTOR:    return MTLBlendFactorBlendColor;
        case D3DM_BLEND_INVBLENDFACTOR: return MTLBlendFactorOneMinusBlendColor;
        default:                        return MTLBlendFactorOne;
    }
}

MTLBlendOperation mapD3dBlendOp(uint32_t op) {
    switch (op) {
        case D3DM_BLENDOP_ADD:         return MTLBlendOperationAdd;
        case D3DM_BLENDOP_SUBTRACT:    return MTLBlendOperationSubtract;
        case D3DM_BLENDOP_REVSUBTRACT: return MTLBlendOperationReverseSubtract;
        case D3DM_BLENDOP_MIN:         return MTLBlendOperationMin;
        case D3DM_BLENDOP_MAX:         return MTLBlendOperationMax;
        default:                       return MTLBlendOperationAdd;
    }
}

MTLCompareFunction mapD3dCmpFunc(uint32_t func) {
    switch (func) {
        case D3DM_CMP_NEVER:        return MTLCompareFunctionNever;
        case D3DM_CMP_LESS:         return MTLCompareFunctionLess;
        case D3DM_CMP_EQUAL:        return MTLCompareFunctionEqual;
        case D3DM_CMP_LESSEQUAL:    return MTLCompareFunctionLessEqual;
        case D3DM_CMP_GREATER:      return MTLCompareFunctionGreater;
        case D3DM_CMP_NOTEQUAL:     return MTLCompareFunctionNotEqual;
        case D3DM_CMP_GREATEREQUAL: return MTLCompareFunctionGreaterEqual;
        case D3DM_CMP_ALWAYS:       return MTLCompareFunctionAlways;
        default:                    return MTLCompareFunctionAlways;
    }
}

MTLStencilOperation mapD3dStencilOp(uint32_t op) {
    switch (op) {
        case D3DM_STENCILOP_KEEP:    return MTLStencilOperationKeep;
        case D3DM_STENCILOP_ZERO:    return MTLStencilOperationZero;
        case D3DM_STENCILOP_REPLACE: return MTLStencilOperationReplace;
        case D3DM_STENCILOP_INCRSAT: return MTLStencilOperationIncrementClamp;
        case D3DM_STENCILOP_DECRSAT: return MTLStencilOperationDecrementClamp;
        case D3DM_STENCILOP_INVERT:  return MTLStencilOperationInvert;
        case D3DM_STENCILOP_INCR:    return MTLStencilOperationIncrementWrap;
        case D3DM_STENCILOP_DECR:    return MTLStencilOperationDecrementWrap;
        default:                     return MTLStencilOperationKeep;
    }
}

MTLSamplerAddressMode mapD3dAddressMode(uint32_t mode) {
    switch (mode) {
        case D3DM_TADDRESS_WRAP:       return MTLSamplerAddressModeRepeat;
        case D3DM_TADDRESS_MIRROR:     return MTLSamplerAddressModeMirrorRepeat;
        case D3DM_TADDRESS_CLAMP:      return MTLSamplerAddressModeClampToEdge;
        case D3DM_TADDRESS_BORDER:     return MTLSamplerAddressModeClampToBorderColor;
        case D3DM_TADDRESS_MIRRORONCE: return MTLSamplerAddressModeMirrorClampToEdge;
        default:                       return MTLSamplerAddressModeRepeat;
    }
}

} // namespace mtl_d3d9
