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
#define VS_SPOTVP   66   // mat4: shadow-casting spotlight view-projection (camera-relative world -> light clip)

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
    float3 worldNormal; // camera-relative world normal, for per-pixel lighting
};

// Normalized surface->camera direction, falling back when the surface sits at
// the camera origin (first-person geometry) so normalize(0) can't produce NaN.
static float3 viewSafe(float3 toView)
{
    return (dot(toView, toView) > 1e-8) ? normalize(toView) : float3(0.0, 0.0, 1.0);
}

// 3x3 PCF sample of the spotlight shadow map.  Returns 1.0 = fully lit, 0.0 =
// fully shadowed.  worldPos is camera-relative world space (same space the light
// view-projection VS_SPOTVP was built in).  Called only for the shadow-casting
// spot (LightDir.w > 1.5); off-map / behind-light samples read as lit.
static float SampleSpotShadow(depth2d<float> shadowTex, sampler shadowSamp, float4x4 lightVP, float3 worldPos)
{
    float4 lc = lightVP * float4(worldPos, 1.0);
    if (lc.w <= 0.0)
        return 1.0; // behind the light
    float3 ndc = lc.xyz / lc.w;
    float2 uv = ndc.xy * float2(0.5, -0.5) + 0.5; // NDC -> tex (flip y for Metal top-left)
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z > 1.0)
        return 1.0; // outside the cone frustum
    const float bias = 0.008; // ndc-space; also masks one-frame animation lag on character casters
    float ref = ndc.z - bias;
    float w = shadowTex.get_width();
    float texel = 1.0 / w;
    float lit = 0.0;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
        {
            float d = shadowTex.sample(shadowSamp, uv + float2(dx, dy) * texel);
            lit += (ref <= d) ? 1.0 : 0.0;
        }
    return lit * (1.0 / 9.0);
}

// Sun + local point/spot lights + sun specular, evaluated at a world position /
// normal.  Shared by vsTransform (per-vertex, for the untextured psFlat path) and
// psNormalLit/psDetailLit (per-pixel).  Mirrors the GL33 vertex-lighting math.
// spotShadow (0..1) attenuates the shadow-casting spot (LightDir.w > 1.5); pass
// 1.0 where no shadow map is sampled (the per-vertex path, and unshadowed spots).
static float4 MeshLighting(constant VSConstants& vc, float3 worldPos, float3 N, thread float3& outSpec,
                           float spotShadow)
{
    float4 sunDir = vc.reg[VS_SUNDIR];
    float4 ambient = vc.reg[VS_AMBIENT];
    float4 diffuse = vc.reg[VS_DIFFUSE];
    float4 emissive = vc.reg[VS_EMISSIVE];
    float sunEn = vc.reg[VS_SUNEN].x;

    float NdotL = max(0.0, dot(N, -sunDir.xyz));
    float4 litColor;
    litColor.rgb = emissive.rgb + ambient.rgb * sunEn + diffuse.rgb * NdotL * sunEn;
    litColor.a = emissive.a + ambient.a * sunEn + diffuse.a * NdotL * sunEn;

    // Local point/spot lights: quadratic falloff past startAtten, cut at 100x;
    // spotlights gate by a cone factor (full inside cos 8deg, zero outside 12deg).
    const float MIN_INSIDE2 = 0.95677279;
    const float MAX_INSIDE2 = 0.98063081;
    int nLights = int(vc.reg[VS_LIGHTCOUNT].x);
    for (int i = 0; i < nLights; i++)
    {
        float4 lp = vc.reg[VS_LIGHTPOS + i];
        float4 ldir = vc.reg[VS_LIGHTDIR + i];
        float3 toLight = lp.xyz - worldPos;
        float size2 = dot(toLight, toLight);
        float startAtten2 = lp.w * lp.w;
        if (size2 >= startAtten2 * 100.0)
            continue;

        float cone = 1.0;
        if (ldir.w > 0.5) // spotlight (w == 1 plain, w == 2 shadow-casting)
        {
            float inside = -dot(toLight, ldir.xyz);
            if (inside <= 0.0)
                continue;
            float cos2 = (inside * inside) / size2;
            if (cos2 < MIN_INSIDE2)
                continue;
            cone = clamp((cos2 - MIN_INSIDE2) / (MAX_INSIDE2 - MIN_INSIDE2), 0.0, 1.0);
        }
        // The shadow-casting spot (w == 2) is masked by the depth map; everything
        // else is fully lit (spotShadow folded in as 1.0 by the caller).
        float sh = (ldir.w > 1.5) ? spotShadow : 1.0;

        float atten = (size2 >= startAtten2) ? (startAtten2 / size2) : 1.0;
        float cosFi = dot(toLight, N);
        float3 ld = vc.reg[VS_LIGHTDIFF + i].rgb;
        float3 la = vc.reg[VS_LIGHTAMB + i].rgb;
        if (cosFi > 0.0)
            litColor.rgb += (ld * (cosFi * rsqrt(size2)) + la) * (atten * cone * sh);
        else
            litColor.rgb += la * (atten * sh);
    }
    litColor = clamp(litColor, 0.0, 1.0);

    float3 spec = float3(0.0);
    float4 specC = vc.reg[VS_SPEC];
    if (vc.reg[VS_SPECEN].x > 0.5 && sunEn > 0.0)
    {
        // Two normalize() guards (NaN -> 0 = black surface):
        //  - toView ~ 0: first-person geometry sits at the camera origin.
        //  - half-vector ~ 0: viewDir == sunDir when looking straight at a
        //    backlit surface ("toward the light") — this was the black gun.
        float3 toView = vc.reg[VS_CAMPOS].xyz - worldPos;
        float3 hv = viewSafe(toView) - sunDir.xyz; // half-vector numerator
        if (dot(hv, hv) > 1e-8)
        {
            float NdotH = max(0.0, dot(N, normalize(hv)));
            spec = specC.rgb * pow(NdotH, max(1.0, specC.w)) * sunEn;
        }
    }
    outSpec = clamp(spec, 0.0, 1.0);
    return litColor;
}

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
    o.worldNormal = float3(0.0);
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
    o.worldNormal = worldNormal;

    // Per-vertex lighting for the untextured psFlat path; psNormalLit/psDetailLit
    // recompute this per-pixel from the interpolated worldRel/worldNormal.
    float3 spec;
    o.color = MeshLighting(vc, worldPos.xyz, worldNormal, spec, 1.0);
    o.spec = float4(spec, 0.0);

    float4 fog = vc.reg[VS_FOG];
    float dist = length(worldPos.xyz - vc.reg[VS_CAMPOS].xyz);
    float fogFactor = clamp(1.0 - (dist - fog.x) * fog.y, 0.0, 1.0);
    o.fogTC = (fog.z > 0.5) ? fogFactor : 1.0;

    float4 texCtrl = vc.reg[VS_TEXCTRL];
    o.uv0 = (texCtrl.x > 0.5) ? (mat4At(vc, VS_TEXMAT0) * float4(vin.uv, 0, 1)).xy : vin.uv;
    o.uv1 = (texCtrl.y > 0.5) ? (mat4At(vc, VS_TEXMAT1) * float4(vin.uv, 0, 1)).xy : vin.uv;
    return o;
}

// ---- Spotlight shadow depth pass ----
// Renders captured opaque geometry from the flashlight's viewpoint into a
// depth texture (VS_SPOTVP = light view-projection).  Reuses the SVertex layout
// and the per-draw world matrix (buffer 2) from the main pass; depth-only, so
// there is no fragment function.
struct DepthOnlyOut
{
    float4 position [[position]];
};
vertex DepthOnlyOut vsSpotDepth(SVertexIn vin [[stage_in]],
                                constant VSConstants& vc [[buffer(1)]],
                                constant WorldInstances& wi [[buffer(2)]],
                                uint iid [[instance_id]])
{
    float4x4 lightVP = mat4At(vc, VS_SPOTVP);
    float4x4 world = wi.world[iid];
    DepthOnlyOut o;
    o.position = lightVP * (world * float4(vin.pos, 1.0));
    return o;
}

// ---- Fullscreen blit (SSAA downscale: frameTex -> drawable) ----
struct BlitOut
{
    float4 pos [[position]];
    float2 uv;
};
vertex BlitOut vsBlit(uint vid [[vertex_id]])
{
    // Fullscreen triangle; uv (0,0) at the top-left to match the frame texture.
    float2 uv = float2((vid << 1) & 2, vid & 2); // (0,0) (2,0) (0,2)
    BlitOut o;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}
fragment float4 psBlit(BlitOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]])
{
    return tex.sample(s, in.uv);
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

// ---- Per-pixel lit variants (the powerful-hardware upgrade) ----
// Same inputs as psNormal/psDetail, but the sun + local lighting is recomputed
// per fragment from the interpolated world position/normal instead of being
// interpolated from the vertices — smooth shading on low-poly geometry.  Needs
// the VS constant block bound at fragment buffer(2).
fragment float4 psNormalLit(VOut in [[stage_in]],
                            constant PSConstants& pc [[buffer(1)]],
                            constant VSConstants& vc [[buffer(2)]],
                            texture2d<float> tex0 [[texture(0)]],
                            sampler samp0 [[sampler(0)]],
                            depth2d<float> shadowTex [[texture(2)]],
                            sampler shadowSamp [[sampler(2)]])
{
    float3 spec;
    float3 N = (dot(in.worldNormal, in.worldNormal) > 1e-8) ? normalize(in.worldNormal) : float3(0.0, 1.0, 0.0);
    float sh = SampleSpotShadow(shadowTex, shadowSamp, mat4At(vc, VS_SPOTVP), in.worldRel);
    float4 lit = MeshLighting(vc, in.worldRel, N, spec, sh);
    float4 col = tex0.sample(samp0, in.uv0) * lit;
    col.rgb += spec;

    float4 alphaRef = pc.reg[PS_ALPHAREF];
    if (col.a - alphaRef.x * alphaRef.y < 0.0)
        discard_fragment();

    col.rgb = mix(pc.reg[PS_FOGCOLOR].rgb, col.rgb, in.fogTC);
    return col;
}

fragment float4 psDetailLit(VOut in [[stage_in]],
                            constant PSConstants& pc [[buffer(1)]],
                            constant VSConstants& vc [[buffer(2)]],
                            texture2d<float> tex0 [[texture(0)]],
                            sampler samp0 [[sampler(0)]],
                            texture2d<float> tex1 [[texture(1)]],
                            sampler samp1 [[sampler(1)]],
                            depth2d<float> shadowTex [[texture(2)]],
                            sampler shadowSamp [[sampler(2)]])
{
    float3 spec;
    float3 N = (dot(in.worldNormal, in.worldNormal) > 1e-8) ? normalize(in.worldNormal) : float3(0.0, 1.0, 0.0);
    float sh = SampleSpotShadow(shadowTex, shadowSamp, mat4At(vc, VS_SPOTVP), in.worldRel);
    float4 lit = MeshLighting(vc, in.worldRel, N, spec, sh);
    float4 col = tex0.sample(samp0, in.uv0) * lit;
    col.rgb *= tex1.sample(samp1, in.uv1).a * 2.0;
    col.rgb += spec;

    float4 alphaRef = pc.reg[PS_ALPHAREF];
    if (col.a - alphaRef.x * alphaRef.y < 0.0)
        discard_fragment();

    col.rgb = mix(pc.reg[PS_FOGCOLOR].rgb, col.rgb, in.fogTC);
    return col;
}
