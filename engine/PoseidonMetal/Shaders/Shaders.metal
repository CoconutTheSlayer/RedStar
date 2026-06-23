#include <metal_stdlib>
using namespace metal;

// Shared VS/PS constant blocks mirrored as raw float4 arrays indexed by the same
// slot numbers as the GL backend's VSConst/PSConst enums (EngineGL33.hpp). This
// preserves the std140 layout and the PSConstants per-shader overloading exactly.
struct VSConstants { float4 reg[70]; };
struct PSConstants { float4 reg[27]; };
struct WorldInstances { float4x4 world[256]; };

// VSConstants slot map (see EngineGL33.hpp VSConst::)
#define VS_PROJ   0   // mat4 c0-3
#define VS_VIEW   4   // mat4 c4-7
#define VS_SUNDIR 12
#define VS_AMBIENT 13
#define VS_DIFFUSE 14
#define VS_EMISSIVE 15
#define VS_FOG 16
#define VS_CAMPOS 17
#define VS_SPEC 18
#define VS_SPECEN 19
#define VS_SUNEN 20
#define VS_VPSCALE 21
#define VS_TEXMAT0 24
#define VS_TEXMAT1 28
#define VS_TEXCTRL 32
#define VS_LIGHTCOUNT 33
#define VS_LIGHTPOS 34   // [8]
#define VS_LIGHTDIFF 42  // [8]
#define VS_LIGHTAMB 50   // [8]
#define VS_LIGHTDIR 58   // [8]

// PSConstants
#define PS_FOGCOLOR 0
#define PS_ALPHAREF 1
#define PS_CONSTCOLOR 3

static inline float4x4 mat4At(constant VSConstants& c, int slot)
{
    return float4x4(c.reg[slot + 0], c.reg[slot + 1], c.reg[slot + 2], c.reg[slot + 3]);
}

// TLVertex (screen-space, pre-transformed 2D).
struct TLVertexIn
{
    float3 pos      [[attribute(0)]];
    float  rhw      [[attribute(1)]];
    float4 color    [[attribute(2)]]; // UChar4Normalized_BGRA -> RGBA float
    float4 specular [[attribute(3)]];
    float2 uv0      [[attribute(4)]];
    float2 uv1      [[attribute(5)]];
};

// SVertex (3D mesh).
struct SVertexIn
{
    float3 pos    [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv     [[attribute(2)]];
};

// Unified vertex output — both vsScreen and vsTransform fill it so psFlat/psNormal
// work for 2D and 3D.
struct VOut
{
    float4 position [[position]];
    float4 color;
    float4 spec;
    float2 uv0;
    float2 uv1;
    float  fogTC;
    float3 worldRel;
};

// ---- Pre-transformed 2D (mirrors s_vsScreenGLSL) ----
vertex VOut vsScreen(TLVertexIn vin [[stage_in]], constant VSConstants& vc [[buffer(1)]])
{
    const float4 vpScale = vc.reg[VS_VPSCALE];
    const float w = 1.0 / vin.rhw;
    VOut o;
    o.position.x = (vin.pos.x * vpScale.x - 1.0) * w;
    o.position.y = (1.0 - vin.pos.y * vpScale.y) * w;
    o.position.z = vin.pos.z * w;
    o.position.w = w;
    o.color = vin.color;
    o.spec = vin.specular;
    o.uv0 = vin.uv0;
    o.uv1 = vin.uv1;
    o.fogTC = vin.specular.a;
    o.worldRel = float3(0.0);
    return o;
}

// ---- 3D transform + lighting + fog (mirrors s_vsTransformGLSL) ----
vertex VOut vsTransform(SVertexIn vin [[stage_in]],
                        constant VSConstants& vc [[buffer(1)]],
                        constant WorldInstances& wi [[buffer(2)]],
                        uint iid [[instance_id]])
{
    float4x4 proj = mat4At(vc, VS_PROJ);
    float4x4 view = mat4At(vc, VS_VIEW);
    float4x4 world = wi.world[iid];

    float4 worldPos = world * float4(vin.pos, 1.0);
    float3 worldNormal = normalize(float3x3(world[0].xyz, world[1].xyz, world[2].xyz) * vin.normal);
    float4 viewPos = view * worldPos;

    VOut o;
    o.position = proj * viewPos;
    o.worldRel = worldPos.xyz;

    float4 sunDir = vc.reg[VS_SUNDIR];
    float4 ambient = vc.reg[VS_AMBIENT];
    float4 diffuse = vc.reg[VS_DIFFUSE];
    float4 emissive = vc.reg[VS_EMISSIVE];
    float sunEn = vc.reg[VS_SUNEN].x;

    float NdotL = max(0.0, dot(worldNormal, -sunDir.xyz));
    float4 litColor;
    litColor.rgb = emissive.rgb + ambient.rgb * sunEn + diffuse.rgb * NdotL * sunEn;
    litColor.a = emissive.a + ambient.a * sunEn + diffuse.a * NdotL * sunEn;

    int nLights = int(vc.reg[VS_LIGHTCOUNT].x);
    for (int i = 0; i < nLights; i++)
    {
        float4 lp = vc.reg[VS_LIGHTPOS + i];
        float3 toLight = lp.xyz - worldPos.xyz;
        float size2 = dot(toLight, toLight);
        float startAtten2 = lp.w * lp.w;
        if (size2 >= startAtten2 * 100.0)
            continue;
        float atten = (size2 >= startAtten2) ? (startAtten2 / size2) : 1.0;
        float cosFi = dot(toLight, worldNormal);
        float3 ld = vc.reg[VS_LIGHTDIFF + i].rgb;
        float3 la = vc.reg[VS_LIGHTAMB + i].rgb;
        if (cosFi > 0.0)
            litColor.rgb += (ld * (cosFi * rsqrt(size2)) + la) * atten;
        else
            litColor.rgb += la * atten;
    }
    o.color = clamp(litColor, 0.0, 1.0);

    float3 spec = float3(0.0);
    float4 specC = vc.reg[VS_SPEC];
    if (vc.reg[VS_SPECEN].x > 0.5 && sunEn > 0.0)
    {
        float3 viewDir = normalize(vc.reg[VS_CAMPOS].xyz - worldPos.xyz);
        float3 halfVec = normalize(-sunDir.xyz + viewDir);
        float NdotH = max(0.0, dot(worldNormal, halfVec));
        spec = specC.rgb * pow(NdotH, max(1.0, specC.w)) * sunEn;
    }
    o.spec = float4(clamp(spec, 0.0, 1.0), 0.0);

    float4 fog = vc.reg[VS_FOG];
    float dist = length(worldPos.xyz - vc.reg[VS_CAMPOS].xyz);
    float fogFactor = clamp(1.0 - (dist - fog.x) * fog.y, 0.0, 1.0);
    o.fogTC = (fog.z > 0.5) ? fogFactor : 1.0;

    float4 texCtrl = vc.reg[VS_TEXCTRL];
    o.uv0 = (texCtrl.x > 0.5) ? (mat4At(vc, VS_TEXMAT0) * float4(vin.uv, 0, 1)).xy : vin.uv;
    o.uv1 = (texCtrl.y > 0.5) ? (mat4At(vc, VS_TEXMAT1) * float4(vin.uv, 0, 1)).xy : vin.uv;
    return o;
}

// ---- Dark-polygon sun shadow (mirrors GL33 vsShadow/psShadow) ----
// The engine projects each caster onto the ground and re-draws it as a flat,
// unlit polygon whose colour is the black + shadowFactor-alpha shadow material
// (SetMaterial writes it to VS_DIFFUSE).  psShadow emits (0,0,0,a) and the
// Shadow blend (ZERO, 1-srcA) darkens the framebuffer: dst' = dst*(1-a).
vertex VOut vsShadow(SVertexIn vin [[stage_in]],
                     constant VSConstants& vc [[buffer(1)]],
                     constant WorldInstances& wi [[buffer(2)]],
                     uint iid [[instance_id]])
{
    float4x4 proj = mat4At(vc, VS_PROJ);
    float4x4 view = mat4At(vc, VS_VIEW);
    float4x4 world = wi.world[iid];
    float4 worldPos = world * float4(vin.pos, 1.0);

    VOut o;
    o.position = proj * (view * worldPos);
    o.color = vc.reg[VS_DIFFUSE]; // black RGB, shadowFactor alpha
    o.spec = float4(0.0);
    float4 texCtrl = vc.reg[VS_TEXCTRL];
    o.uv0 = (texCtrl.x > 0.5) ? (mat4At(vc, VS_TEXMAT0) * float4(vin.uv, 0, 1)).xy : vin.uv;
    o.uv1 = o.uv0;
    o.fogTC = 1.0; // shadows ignore fog
    o.worldRel = float3(0.0);
    return o;
}

fragment float4 psShadow(VOut in [[stage_in]],
                         constant PSConstants& pc [[buffer(1)]],
                         texture2d<float> tex0 [[texture(0)]],
                         sampler samp0 [[sampler(0)]])
{
    // Opaque casters bind a 1x1 white texture (alpha 1); foliage casters keep
    // their texture so the cutout silhouette discards transparent texels.
    float a = in.color.a * tex0.sample(samp0, in.uv0).a;
    float4 alphaRef = pc.reg[PS_ALPHAREF];
    if (a - alphaRef.x * alphaRef.y < 0.0)
        discard_fragment();
    return float4(0.0, 0.0, 0.0, a);
}

// ---- Fragment ----
fragment float4 psFlat(VOut in [[stage_in]])
{
    return in.color;
}

fragment float4 psNormal(VOut in [[stage_in]],
                         constant PSConstants& pc [[buffer(1)]],
                         texture2d<float> tex0 [[texture(0)]],
                         sampler samp0 [[sampler(0)]])
{
    float4 t = tex0.sample(samp0, in.uv0);
    float4 col = t * in.color;
    col.rgb += in.spec.rgb;

    float4 alphaRef = pc.reg[PS_ALPHAREF];
    if (col.a - alphaRef.x * alphaRef.y < 0.0)
        discard_fragment();

    col.rgb = mix(pc.reg[PS_FOGCOLOR].rgb, col.rgb, in.fogTC);
    return col;
}

// ---- Multitextured detail (terrain): base tex0(uv0) * detail tex1(uv1) ----
// Mirrors GL33 psDetail: the detail texture's alpha, doubled, modulates the base
// colour ("rgb *= t1.a * 2.0" — a signed-around-0.5 modulate that adds the
// high-frequency surface detail).  uv1 = uv0 * 32 (see vsTransform texgen).
fragment float4 psDetail(VOut in [[stage_in]],
                         constant PSConstants& pc [[buffer(1)]],
                         texture2d<float> tex0 [[texture(0)]],
                         sampler samp0 [[sampler(0)]],
                         texture2d<float> tex1 [[texture(1)]],
                         sampler samp1 [[sampler(1)]])
{
    float4 t0 = tex0.sample(samp0, in.uv0);
    float4 t1 = tex1.sample(samp1, in.uv1);
    float4 col = t0 * in.color;
    col.rgb *= t1.a * 2.0;
    col.rgb += in.spec.rgb;

    float4 alphaRef = pc.reg[PS_ALPHAREF];
    if (col.a - alphaRef.x * alphaRef.y < 0.0)
        discard_fragment();

    col.rgb = mix(pc.reg[PS_FOGCOLOR].rgb, col.rgb, in.fogTC);
    return col;
}
