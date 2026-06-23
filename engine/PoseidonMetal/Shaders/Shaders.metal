#include <metal_stdlib>
using namespace metal;

// Shared VS/PS constant blocks mirrored as raw float4 arrays indexed by the same
// slot numbers as the GL backend's VSConst/PSConst enums (EngineGL33.hpp). This
// preserves the std140 layout and the PSConstants per-shader overloading exactly.
struct VSConstants { float4 reg[70]; };
struct PSConstants { float4 reg[27]; };

// TLVertex (screen-space, pre-transformed). Attribute offsets/stride come from
// the MTLVertexDescriptor built in EngineMetal_Pipeline.mm (offsetof(TLVertex)).
struct TLVertexIn
{
    float3 pos      [[attribute(0)]];
    float  rhw      [[attribute(1)]];
    float4 color    [[attribute(2)]]; // UChar4Normalized_BGRA -> RGBA float
    float4 specular [[attribute(3)]];
    float2 uv0      [[attribute(4)]];
    float2 uv1      [[attribute(5)]];
};

struct ScreenInOut
{
    float4 position [[position]];
    float4 color;
    float4 spec;
    float2 uv0;
    float2 uv1;
};

// Pre-transformed 2D vertex shader. Mirrors s_vsScreenGLSL: pixel-space pos ->
// clip space using vpScale = {2/width, 2/height} at VSConst slot 21. Metal clip
// space matches GL (Y up), so the formula is identical.
vertex ScreenInOut vsScreen(TLVertexIn vin [[stage_in]],
                            constant VSConstants& vc [[buffer(1)]])
{
    const float4 vpScale = vc.reg[21];
    const float w = 1.0 / vin.rhw;
    ScreenInOut o;
    o.position.x = (vin.pos.x * vpScale.x - 1.0) * w;
    o.position.y = (1.0 - vin.pos.y * vpScale.y) * w;
    o.position.z = vin.pos.z * w;
    o.position.w = w;
    o.color = vin.color;
    o.spec = vin.specular;
    o.uv0 = vin.uv0;
    o.uv1 = vin.uv1;
    return o;
}

// Vertex-color passthrough (mirrors s_psFlatGLSL).
fragment float4 psFlat(ScreenInOut in [[stage_in]])
{
    return in.color;
}

// Diffuse texture * vertex color (M2 minimal psNormal; shadows/fog added M3/M5).
fragment float4 psNormal(ScreenInOut in [[stage_in]],
                         texture2d<float> tex0 [[texture(0)]],
                         sampler samp0 [[sampler(0)]])
{
    const float4 t = tex0.sample(samp0, in.uv0);
    return t * in.color;
}
