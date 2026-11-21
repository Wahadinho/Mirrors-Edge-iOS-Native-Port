#pragma once

#import <Metal/Metal.h>
#include "d3d9_metal_types.h"
#include "d3d9_metal_enums.h"
#include <cstdint>

namespace mtl_d3d9 {

struct MtlFormatInfo {
    MTLPixelFormat pixelFormat     = MTLPixelFormatInvalid;
    MTLPixelFormat srgbPixelFormat = MTLPixelFormatInvalid;
    uint32_t bytesPerPixel         = 0;
    uint32_t blockWidth            = 1;
    uint32_t blockHeight           = 1;
    uint32_t blockBytes            = 0;
    bool hasSwizzle                = false;
    MTLTextureSwizzleChannels swizzle = { MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha };
    bool hasAlpha                  = false;
    bool isDepth                   = false;
    bool hasStencil                = false;
    bool isRawDepthFetch           = false; /* INTZ / DF16 / DF24 */
    bool isFloat                   = false;
    bool isNullFormat              = false; /* D3DFMT_NULL */
};

MtlFormatInfo mapD3dFormat(uint32_t d3dFormat);
uint32_t calcRowPitch(uint32_t d3dFormat, uint32_t width);
uint32_t calcRowCount(uint32_t d3dFormat, uint32_t height);
uint32_t calcSliceSize(uint32_t d3dFormat, uint32_t width, uint32_t height);
MTLVertexFormat mapD3dDeclType(uint8_t declType);
MTLBlendFactor mapD3dBlendFactor(uint32_t blend, bool targetHasAlpha);
MTLBlendOperation mapD3dBlendOp(uint32_t op);
MTLCompareFunction mapD3dCmpFunc(uint32_t func);
MTLStencilOperation mapD3dStencilOp(uint32_t op);
MTLSamplerAddressMode mapD3dAddressMode(uint32_t mode);

} // namespace mtl_d3d9
