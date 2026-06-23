#pragma once

#ifndef __MATRIX_CONVERSION_HPP
#define __MATRIX_CONVERSION_HPP

#include <Poseidon/Foundation/Math/Math3D.hpp>

// GfxMatrix: portable 4x4 float matrix with the same memory layout as D3DMATRIX.
// On Windows this is ABI-compatible with D3DMATRIX (both are 16 contiguous floats
// with identical named members). We define our own struct to avoid pulling in
// d3d9types.h (which requires <windows.h>).

namespace Poseidon
{
struct GfxMatrix
{
    union
    {
        struct
        {
            float _11, _12, _13, _14;
            float _21, _22, _23, _24;
            float _31, _32, _33, _34;
            float _41, _42, _43, _44;
        };
        float m[4][4];
    };
};

// True when the active GPU's clip-space depth range is [0, 1] — the D3D /
// Vulkan "zero-to-one" convention, which the GL33 backend normally gets via
// glClipControl(GL_ZERO_TO_ONE).  False when running on a GL context without
// ARB_clip_control (notably macOS, whose OpenGL is capped at 4.1): in that
// case ConvertProjectionMatrix remaps the projection so NDC z lands in GL's
// native [-1, 1] range.  The remap is depth-equivalent — window-space depth
// (and therefore shadow-map contents) come out identical — so the rest of the
// pipeline is unaffected.  Set once by the backend at init; defaults to true,
// which keeps Windows/Linux behaviour byte-for-byte unchanged.
extern bool gGpuClipZeroToOne;

// Row-major; maps the OFP coordinate system into the graphics matrix.
void ConvertMatrix(GfxMatrix& mat, Matrix4Val src);
void ConvertMatrixTransposed(GfxMatrix& mat, Matrix4Val src);
void ConvertProjectionMatrix(GfxMatrix& mat, Matrix4Val src, float zBias);

} // namespace Poseidon
#endif
