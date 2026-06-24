#include <PoseidonMetal/EngineMetal.hpp>
#include <PoseidonMetal/EngineFactoryMetal.hpp>

#include <PoseidonMetal/TextureMetal.hpp>
#include <Poseidon/Graphics/Shared/ScreenshotWriter.hpp>
#include <Poseidon/Graphics/Core/TLVertex.hpp>
#include <Poseidon/Graphics/Core/MatrixConversion.hpp>
#include <Poseidon/Graphics/Rendering/Primitives/Vertex.hpp>
#include <Poseidon/Graphics/Rendering/Primitives/Poly.hpp>
#include <Poseidon/Graphics/Rendering/Lighting/Lights.hpp>
#include <Poseidon/Graphics/Rendering/RenderFlags.hpp>
#include <Poseidon/Graphics/Rendering/BuildRenderPassDescriptor.hpp>
#include <Poseidon/World/Scene/Scene.hpp>
#include <Poseidon/World/Scene/Camera/Camera.hpp>
#include <Poseidon/Core/Application.hpp>
#include <Poseidon/Core/Global.hpp>
#include <Poseidon/Foundation/Framework/AppFrame.hpp>
#include <Poseidon/Foundation/Framework/Log.hpp>

#include <cstddef> // offsetof
#include <cmath>   // sqrtf / tanf / fabsf for the spotlight matrix

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#include <vector>

// Dev-overlay ImGui backend (Metal). Poseidon's DebugLog macro collides with
// ImGuiContext::DebugLog — undef before including imgui (same guard GL33 uses).
#include <Poseidon/Dev/Debug/DebugOverlay.hpp>
#ifdef DebugLog
#undef DebugLog
#endif
#include <imgui.h>
#include <imgui_impl_sdl3.h>
#include <imgui_impl_metal.h>

// Shared SDL input buffers (InputProcessing_sdl.cpp) — same handlers GL33/Dummy use.
extern void SDLInput_BufferKeyEvent(SDL_Scancode sc, bool down, DWORD timestamp);
extern void SDLInput_BufferMouseButton(int btn, bool down);
extern void SDLInput_BufferMouseMotion(float dx, float dy);
extern void SDLInput_BufferMouseWheel(float dy);
extern void SDLInput_BufferUIKeyEvent(SDL_Keycode key, bool down);
extern void SDLInput_BufferUICharEvent(const char* text);

namespace Poseidon
{

// VS/PS constant-block slot indices (vec4 units).  Must match the slot map in
// Shaders/Shaders.metal (VS_*/PS_* #defines) and EngineGL33's VSConst/PSConst.
namespace VSlot
{
enum
{
    Proj = 0,
    View = 4,
    SunDir = 12,
    Ambient = 13,
    Diffuse = 14,
    Emissive = 15,
    Fog = 16,
    CamPos = 17,
    Spec = 18,
    SpecEn = 19,
    SunEn = 20,
    VpScale = 21,
    TexMat0 = 24,
    TexMat1 = 28,
    TexCtrl = 32,
    LightCount = 33,
    LightPos = 34,     // [MaxLocalLights] xyz camera-relative pos, w = startAtten
    LightDiffuse = 42, // [MaxLocalLights] rgb diffuse * mat * nightEffect
    LightAmbient = 50, // [MaxLocalLights] rgb ambient * mat * nightEffect
    LightDir = 58,     // [MaxLocalLights] xyz beam dir, w = 0 point / 1 spot / 2 shadow-casting spot
    SpotVP = 66,       // mat4: shadow-casting spotlight view-projection
};
constexpr int MaxLocalLights = 8;
} // namespace VSlot
namespace PSlot
{
enum
{
    FogColor = 0,
    AlphaRef = 1,
    ConstColor = 3,
};
} // namespace PSlot

// One opaque mesh draw captured during the main pass, replayed into the
// spotlight shadow map at the start of the next frame (one-frame-deferred so the
// geometry is known before the depth pass that must precede the main pass).
struct ShadowCaster
{
    id<MTLBuffer> vbo = nil; // retained snapshot — dynamic meshes get a fresh vbo per frame
    id<MTLBuffer> ibo = nil;
    int firstIndex = 0;
    int indexCount = 0;
    bool dynamic = false; // animated mesh — gets extra depth bias (one-frame lag acne)
    float world[16] = {};
};

// All Objective-C / Metal state lives here so EngineMetal.hpp stays pure C++.
struct MetalState
{
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    SDL_MetalView view = nullptr;
    CAMetalLayer* layer = nil;

    id<MTLTexture> frameTex = nil; // offscreen BGRA8, shared storage (CPU-readable for screenshots)
    id<MTLCommandBuffer> cmd = nil;
    id<MTLRenderCommandEncoder> enc = nil; // persistent per-frame render encoder
    int texW = 0;
    int texH = 0;

    // MSAA: when sampleCount>1, the scene renders into msaaColor (+ a multisample
    // depth/stencil) and resolves into the single-sample frameTex on store.
    int sampleCount = 1;
    id<MTLTexture> msaaColor = nil;
    int msaaW = 0, msaaH = 0;
    bool alphaToCoverage = false; // grade cutout (alpha-test) edges across MSAA samples

    // SSAA: frameTex/msaaColor/depth are sized renderScale x the drawable; on
    // present a fullscreen blit downsamples frameTex into the window-size drawable.
    float renderScale = 1.0f;
    id<MTLRenderPipelineState> psoBlit = nil; // fullscreen tex->drawable downscale

    // 2D TLVertexTable soup path (UI / options notebook): BeginMesh stashes the
    // current screen-space vertex array, PrepareTriangle the texture + per-draw
    // depth/sampler state (so depth-tested 3D content like terrain submitted
    // through this path doesn't overdraw as flat no-depth quads).
    const Poseidon::TLVertex* soupVerts = nullptr;
    int soupCount = 0;
    id<MTLTexture> soupTex = nil;
    id<MTLDepthStencilState> soupDepth = nil; // set per PrepareTriangle from the spec
    id<MTLSamplerState> soupSampler = nil;

    // Shaders / pipeline (M2 spine)
    id<MTLLibrary> lib = nil;
    id<MTLRenderPipelineState> psoFlat = nil;   // vsScreen + psFlat (2D)
    id<MTLRenderPipelineState> psoNormal = nil; // vsScreen + psNormal (2D)
    // Sampler table indexed by (point<<2)|(clampU<<0)|(clampV<<1), mirroring
    // EngineGL33's _samplerObjects[8].
    id<MTLSamplerState> samplers[8] = {};

    // 3D mesh (M3)
    id<MTLRenderPipelineState> psoMesh = nil;     // vsTransform + psNormal
    id<MTLRenderPipelineState> psoMeshBlend = nil; // vsTransform + psNormal + alpha blend
    id<MTLRenderPipelineState> psoMeshDetail = nil; // vsTransform + psDetail (terrain base*detail)
    id<MTLRenderPipelineState> psoMeshFlat = nil; // vsTransform + psFlat
    id<MTLRenderPipelineState> psoMeshShadow = nil; // vsShadow + psShadow (dark projected polygon)
    id<MTLTexture> depthTex = nil;
    id<MTLDepthStencilState> dss3D = nil; // LEQUAL + write (DepthMode::Normal)
    id<MTLDepthStencilState> dss3DNoWrite = nil; // LEQUAL, no write (NoZWrite surfaces)
    id<MTLDepthStencilState> dss2D = nil; // always pass, no write
    id<MTLDepthStencilState> dssShadow = nil; // LEQUAL no-write, stencil EQUAL 0 / INCR
    int depthW = 0, depthH = 0;

    id<MTLTexture> meshTex = nil; // current section texture (set by PrepareTriangleTL)
    id<MTLTexture> fallbackWhiteTex = nil; // 1x1 white for untextured mesh draws (GL33 parity)

    // Triple-buffered dynamic vertex ring for 2D immediate-mode geometry.
    static constexpr int kRingCount = 3;
    static constexpr size_t kRingBytes = 4 * 1024 * 1024; // ~100k TLVertex
    id<MTLBuffer> ring[kRingCount] = {nil, nil, nil};
    dispatch_semaphore_t sem = nil;
    uint64_t frameCount = 0;
    id<MTLBuffer> curRing = nil;
    size_t ringUsed = 0;

    // Spotlight shadow map (flashlight): a single depth texture rendered from the
    // light's viewpoint each frame, sampled by the per-pixel mesh shaders.
    static constexpr int kSpotShadowSize = 2048;
    id<MTLTexture> spotShadowTex = nil;
    id<MTLRenderPipelineState> psoSpotDepth = nil; // vsSpotDepth, depth-only
    id<MTLDepthStencilState> dssSpotDepth = nil;   // LEQUAL + write
    id<MTLSamplerState> shadowSampler = nil;       // clamp, nearest (manual PCF)
    std::vector<ShadowCaster> casters;             // captured this frame, drawn next

    // Dev-overlay (ImGui) — rendered into a drawable-backed pass at Present time.
    bool imguiReady = false;
    MTLRenderPassDescriptor* overlayPassDesc = nil;   // valid only during the Present overlay pass
    id<MTLRenderCommandEncoder> overlayEnc = nil;     // ditto — what RenderDrawData encodes into
};

// Build a MTLVertexDescriptor matching the TLVertex memory layout. Offsets come
// from the C++ struct via offsetof so they can never drift from the engine side.
static MTLVertexDescriptor* MakeTLVertexDescriptor()
{
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3; // pos
    vd.attributes[0].offset = offsetof(Poseidon::TLVertex, pos);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat; // rhw
    vd.attributes[1].offset = offsetof(Poseidon::TLVertex, rhw);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatUChar4Normalized_BGRA; // color (BGRA8 -> RGBA)
    vd.attributes[2].offset = offsetof(Poseidon::TLVertex, color);
    vd.attributes[2].bufferIndex = 0;
    vd.attributes[3].format = MTLVertexFormatUChar4Normalized_BGRA; // specular
    vd.attributes[3].offset = offsetof(Poseidon::TLVertex, specular);
    vd.attributes[3].bufferIndex = 0;
    vd.attributes[4].format = MTLVertexFormatFloat2; // uv0
    vd.attributes[4].offset = offsetof(Poseidon::TLVertex, t0);
    vd.attributes[4].bufferIndex = 0;
    vd.attributes[5].format = MTLVertexFormatFloat2; // uv1
    vd.attributes[5].offset = offsetof(Poseidon::TLVertex, t1);
    vd.attributes[5].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(Poseidon::TLVertex);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    return vd;
}

static MTLVertexDescriptor* MakeSVertexDescriptor()
{
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat3; // pos
    vd.attributes[0].offset = 0;
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format = MTLVertexFormatFloat3; // normal
    vd.attributes[1].offset = sizeof(Vector3P);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format = MTLVertexFormatFloat2; // uv
    vd.attributes[2].offset = sizeof(Vector3P) * 2;
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride = sizeof(Vector3P) * 2 + sizeof(Poseidon::UVPair);
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    return vd;
}

// Depth+stencil format used by every render pass — stencil is needed for the
// dark-polygon shadow overlap mask (EQUAL 0 / INCR).
static constexpr MTLPixelFormat kDepthStencilFormat = MTLPixelFormatDepth32Float_Stencil8;

enum class MtlBlend
{
    None,   // opaque
    Alpha,  // src.a, 1-src.a (standard alpha)
    Shadow, // RGB: (ZERO, 1-src.a) => dst*=(1-a) darken; A: (ONE, ZERO)
};

static id<MTLRenderPipelineState> MakePSO(id<MTLDevice> dev, id<MTLLibrary> lib, const char* vsName,
                                          const char* psName, MTLPixelFormat colorFmt, MtlBlend blend,
                                          MTLVertexDescriptor* vdesc, NSUInteger sampleCount, bool alphaToCoverage)
{
    id<MTLFunction> vs = [lib newFunctionWithName:[NSString stringWithUTF8String:vsName]];
    id<MTLFunction> ps = [lib newFunctionWithName:[NSString stringWithUTF8String:psName]];
    if (!vs || !ps)
    {
        LOG_ERROR(Graphics, "Metal: missing shader function {} / {}", vsName, psName);
        return nil;
    }
    MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = vs;
    pd.fragmentFunction = ps;
    pd.vertexDescriptor = vdesc;
    pd.rasterSampleCount = sampleCount; // must match the (MSAA) render-pass attachments
    pd.alphaToCoverageEnabled = (alphaToCoverage && sampleCount > 1); // grade cutout edges (MSAA only)
    pd.depthAttachmentPixelFormat = kDepthStencilFormat; // render pass carries depth+stencil
    pd.stencilAttachmentPixelFormat = kDepthStencilFormat;
    pd.colorAttachments[0].pixelFormat = colorFmt;
    if (blend == MtlBlend::Alpha)
    {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    else if (blend == MtlBlend::Shadow)
    {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorZero;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso)
        LOG_ERROR(Graphics, "Metal: PSO ({}/{}) failed: {}", vsName, psName,
                  err ? [[err localizedDescription] UTF8String] : "?");
    return pso;
}

// (Re)build every render pipeline state for the given MSAA sample count.  The
// rasterSampleCount must match the render-pass attachments, so changing MSAA
// rebuilds all PSOs.
static void BuildPipelines(MetalState* m, int sampleCount)
{
    const NSUInteger sc = (NSUInteger)(sampleCount < 1 ? 1 : sampleCount);
    const MTLPixelFormat cf = MTLPixelFormatBGRA8Unorm;
    const bool a2c = m->alphaToCoverage; // only effective on the opaque/cutout mesh PSOs + MSAA
    m->psoFlat = MakePSO(m->device, m->lib, "vsScreen", "psFlat", cf, MtlBlend::Alpha, MakeTLVertexDescriptor(), sc, false);
    m->psoNormal = MakePSO(m->device, m->lib, "vsScreen", "psNormal", cf, MtlBlend::Alpha, MakeTLVertexDescriptor(), sc, false);
    // 3D textured meshes use the per-pixel lit fragment shaders.
    m->psoMesh = MakePSO(m->device, m->lib, "vsTransform", "psNormalLit", cf, MtlBlend::None, MakeSVertexDescriptor(), sc, a2c);
    m->psoMeshBlend = MakePSO(m->device, m->lib, "vsTransform", "psNormalLit", cf, MtlBlend::Alpha, MakeSVertexDescriptor(), sc, false);
    m->psoMeshDetail = MakePSO(m->device, m->lib, "vsTransform", "psDetailLit", cf, MtlBlend::None, MakeSVertexDescriptor(), sc, a2c);
    m->psoMeshFlat = MakePSO(m->device, m->lib, "vsTransform", "psFlat", cf, MtlBlend::None, MakeSVertexDescriptor(), sc, false);
    // Dark-polygon sun shadow: black + shadowFactor alpha, ZERO/1-srcA darken blend.
    m->psoMeshShadow = MakePSO(m->device, m->lib, "vsShadow", "psShadow", cf, MtlBlend::Shadow, MakeSVertexDescriptor(), sc, a2c);
    m->sampleCount = (int)sc;
}

static bool LoadShaders(MetalState* m)
{
    NSError* err = nil;
    NSString* path = [NSString stringWithUTF8String:POSEIDON_METALLIB_PATH];
    m->lib = [m->device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&err];
    if (!m->lib)
    {
        // Fallback: Poseidon.metallib next to the executable (dist layout).
        if (const char* base = SDL_GetBasePath())
        {
            NSString* p2 = [NSString stringWithFormat:@"%sPoseidon.metallib", base];
            m->lib = [m->device newLibraryWithURL:[NSURL fileURLWithPath:p2] error:&err];
        }
    }
    if (!m->lib)
    {
        LOG_ERROR(Graphics, "Metal: failed to load metallib ({})",
                  err ? [[err localizedDescription] UTF8String] : "not found");
        return false;
    }

    BuildPipelines(m, m->sampleCount);

    // SSAA downscale blit PSO: fullscreen triangle (no vertex buffer), samples
    // frameTex into the single-sample, depth-less drawable.
    {
        id<MTLFunction> bvs = [m->lib newFunctionWithName:@"vsBlit"];
        id<MTLFunction> bps = [m->lib newFunctionWithName:@"psBlit"];
        MTLRenderPipelineDescriptor* bd = [[MTLRenderPipelineDescriptor alloc] init];
        bd.vertexFunction = bvs;
        bd.fragmentFunction = bps;
        bd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError* berr = nil;
        m->psoBlit = [m->device newRenderPipelineStateWithDescriptor:bd error:&berr];
        if (!m->psoBlit)
            LOG_ERROR(Graphics, "Metal: blit PSO failed: {}", berr ? [[berr localizedDescription] UTF8String] : "?");
    }

    for (int i = 0; i < 8; i++)
    {
        const bool clampU = (i & 1) != 0;
        const bool clampV = (i & 2) != 0;
        const bool point = (i & 4) != 0;
        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = point ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sd.magFilter = point ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sd.mipFilter = point ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
        sd.sAddressMode = clampU ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        sd.tAddressMode = clampV ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
        // 16x anisotropic filtering on the linear samplers — a free modern-GPU win
        // the original engine never used; keeps terrain/road textures sharp at
        // grazing angles instead of smearing into the distance.
        sd.maxAnisotropy = point ? 1 : 16;
        m->samplers[i] = [m->device newSamplerStateWithDescriptor:sd];
    }

    // Stencil for the dark-polygon shadow overlap mask (mirrors GL33):
    //  - non-shadow draws: ALWAYS / REPLACE 0 — every drawn pixel re-zeroes the
    //    mask so the next caster's shadow starts clean.
    //  - shadow draws: EQUAL 0 / INCR — darken a receiver pixel at most once per
    //    caster (overlapping projected polys of one caster then fail).
    auto resetStencil = [] {
        MTLStencilDescriptor* s = [[MTLStencilDescriptor alloc] init];
        s.stencilCompareFunction = MTLCompareFunctionAlways;
        s.stencilFailureOperation = MTLStencilOperationKeep;
        s.depthFailureOperation = MTLStencilOperationKeep;
        s.depthStencilPassOperation = MTLStencilOperationReplace; // write ref (0)
        s.readMask = 0xFF;
        s.writeMask = 0xFF;
        return s;
    };

    // Depth-stencil states: 3D = LEQUAL + write; 2D = always pass, no write.
    MTLDepthStencilDescriptor* d3 = [[MTLDepthStencilDescriptor alloc] init];
    d3.depthCompareFunction = MTLCompareFunctionLessEqual;
    d3.depthWriteEnabled = YES;
    d3.frontFaceStencil = resetStencil();
    d3.backFaceStencil = resetStencil();
    m->dss3D = [m->device newDepthStencilStateWithDescriptor:d3];
    MTLDepthStencilDescriptor* d3nw = [[MTLDepthStencilDescriptor alloc] init];
    d3nw.depthCompareFunction = MTLCompareFunctionLessEqual;
    d3nw.depthWriteEnabled = NO;
    d3nw.frontFaceStencil = resetStencil();
    d3nw.backFaceStencil = resetStencil();
    m->dss3DNoWrite = [m->device newDepthStencilStateWithDescriptor:d3nw];
    MTLDepthStencilDescriptor* d2 = [[MTLDepthStencilDescriptor alloc] init];
    d2.depthCompareFunction = MTLCompareFunctionAlways;
    d2.depthWriteEnabled = NO;
    m->dss2D = [m->device newDepthStencilStateWithDescriptor:d2];

    // Shadow: LEQUAL, no depth write, stencil EQUAL 0 then INCR.
    MTLStencilDescriptor* sShadow = [[MTLStencilDescriptor alloc] init];
    sShadow.stencilCompareFunction = MTLCompareFunctionEqual;
    sShadow.stencilFailureOperation = MTLStencilOperationKeep;
    sShadow.depthFailureOperation = MTLStencilOperationKeep;
    sShadow.depthStencilPassOperation = MTLStencilOperationIncrementClamp;
    sShadow.readMask = 0xFF;
    sShadow.writeMask = 0xFF;
    MTLDepthStencilDescriptor* dsh = [[MTLDepthStencilDescriptor alloc] init];
    dsh.depthCompareFunction = MTLCompareFunctionLessEqual;
    dsh.depthWriteEnabled = NO;
    dsh.frontFaceStencil = sShadow;
    dsh.backFaceStencil = sShadow;
    m->dssShadow = [m->device newDepthStencilStateWithDescriptor:dsh];

    // 1x1 white fallback (matches GL33 _fallbackWhiteTex).
    {
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        m->fallbackWhiteTex = [m->device newTextureWithDescriptor:td];
        const uint8_t white[4] = {255, 255, 255, 255};
        [m->fallbackWhiteTex replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                              mipmapLevel:0
                                withBytes:white
                              bytesPerRow:4];
    }

    // Spotlight shadow map: a depth-only pipeline (no fragment shader), a fixed
    // 2048^2 Depth32Float texture, a LEQUAL+write depth state, and a clamped
    // nearest sampler (the shader does manual 3x3 PCF).
    {
        id<MTLFunction> sdvs = [m->lib newFunctionWithName:@"vsSpotDepth"];
        MTLRenderPipelineDescriptor* pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = sdvs;
        pd.fragmentFunction = nil; // depth-only
        pd.vertexDescriptor = MakeSVertexDescriptor();
        pd.rasterSampleCount = 1;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        NSError* serr = nil;
        m->psoSpotDepth = [m->device newRenderPipelineStateWithDescriptor:pd error:&serr];
        if (!m->psoSpotDepth)
            LOG_ERROR(Graphics, "Metal: spot-depth PSO failed: {}",
                      serr ? [[serr localizedDescription] UTF8String] : "?");

        MTLDepthStencilDescriptor* dd = [[MTLDepthStencilDescriptor alloc] init];
        dd.depthCompareFunction = MTLCompareFunctionLessEqual;
        dd.depthWriteEnabled = YES;
        m->dssSpotDepth = [m->device newDepthStencilStateWithDescriptor:dd];

        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                               width:MetalState::kSpotShadowSize
                                                              height:MetalState::kSpotShadowSize
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        m->spotShadowTex = [m->device newTextureWithDescriptor:td];

        MTLSamplerDescriptor* ss = [[MTLSamplerDescriptor alloc] init];
        ss.minFilter = MTLSamplerMinMagFilterNearest;
        ss.magFilter = MTLSamplerMinMagFilterNearest;
        ss.sAddressMode = MTLSamplerAddressModeClampToEdge;
        ss.tAddressMode = MTLSamplerAddressModeClampToEdge;
        m->shadowSampler = [m->device newSamplerStateWithDescriptor:ss];
    }

    LOG_INFO(Graphics, "Metal: shaders loaded (2D={}, mesh={})", m->psoFlat != nil, m->psoMesh != nil);
    return m->psoFlat != nil && m->psoMesh != nil;
}

// Fan-triangulate n screen-space TLVertices into the current ring buffer and
// draw them via the given pipeline. tex==nil uses vertex color only (psFlat);
// a non-nil texture binds tex0+sampler for psNormal.
// Sampler table index: (point<<2)|(clampU<<0)|(clampV<<1) — matches MetalState::samplers.
static inline int SamplerIdx(bool clampU, bool clampV, bool point)
{
    return (point ? 4 : 0) | (clampU ? 1 : 0) | (clampV ? 2 : 0);
}

static void EmitPolyFan(MetalState* m, const Poseidon::TLVertex* v, int n, id<MTLRenderPipelineState> pso,
                        id<MTLTexture> tex, int w, int h, id<MTLDepthStencilState> depthState,
                        id<MTLSamplerState> sampler)
{
    if (!m->enc || !pso || n < 3 || !m->curRing)
        return;
    const int triVerts = (n - 2) * 3;
    const size_t need = (size_t)triVerts * sizeof(Poseidon::TLVertex);

    // 256-byte align the ring offset (safe for setVertexBuffer:offset:).
    m->ringUsed = (m->ringUsed + 255) & ~size_t(255);
    if (m->ringUsed + need > MetalState::kRingBytes)
        m->ringUsed = 0; // best-effort wrap (frame exceeded ring capacity)

    auto* dst = (Poseidon::TLVertex*)((uint8_t*)[m->curRing contents] + m->ringUsed);
    int o = 0;
    for (int i = 1; i + 1 < n; i++)
    {
        dst[o++] = v[0];
        dst[o++] = v[i];
        dst[o++] = v[i + 1];
    }

    float vsConst[70 * 4] = {0};
    vsConst[VSlot::VpScale * 4 + 0] = 2.0f / w;
    vsConst[VSlot::VpScale * 4 + 1] = 2.0f / h;

    [m->enc setRenderPipelineState:pso];
    [m->enc setDepthStencilState:depthState];
    [m->enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f]; // clear any 3D OnSurface bias
    [m->enc setVertexBuffer:m->curRing offset:m->ringUsed atIndex:0];
    [m->enc setVertexBytes:vsConst length:sizeof(vsConst) atIndex:1];
    if (tex)
    {
        [m->enc setFragmentTexture:tex atIndex:0];
        [m->enc setFragmentSamplerState:sampler atIndex:0];
    }
    [m->enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:triVerts];

    m->ringUsed += need;
}

// Immediate 2D UI fan: no depth test, clamp+linear sampler (Draw2D/DrawPoly/DrawLine).
static inline void EmitUI(MetalState* m, const Poseidon::TLVertex* v, int n, id<MTLRenderPipelineState> pso,
                          id<MTLTexture> tex, int w, int h)
{
    EmitPolyFan(m, v, n, pso, tex, w, h, m->dss2D, m->samplers[SamplerIdx(true, true, false)]);
}

EngineMetal::EngineMetal(int width, int height, bool windowed, int bpp)
{
    _w = width;
    _h = height;
    _pixelSize = bpp > 0 ? bpp : 32;
    _windowed = windowed;
    // Metal NDC depth is natively [0,1], so projection matrices stay zero-to-one
    // (no clip-control remap — unlike the macOS GL path). See MatrixConversion.
    Poseidon::gGpuClipZeroToOne = true;
    _m = new MetalState();

    if (!CreateWindowAndDevice(width, height, windowed))
        LOG_ERROR(Graphics, "Metal: initialization failed");

    _bank = new TextBankMetal(_m->device); // device now exists
}

EngineMetal::~EngineMetal()
{
    DestroyMetal();
    if (_bank)
    {
        delete _bank;
        _bank = nullptr;
    }
    delete _m;
    _m = nullptr;
}

bool EngineMetal::CreateWindowAndDevice(int width, int height, bool windowed)
{
    LOG_INFO(Graphics, "Metal: Initializing engine — {}x{} {}bpp {}", width, height, _pixelSize,
             windowed ? "windowed" : "fullscreen");

    if (!SDL_Init(SDL_INIT_VIDEO))
    {
        LOG_ERROR(Graphics, "Metal: SDL_Init failed: {}", SDL_GetError());
        return false;
    }

    Uint32 flags = SDL_WINDOW_METAL | SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (windowed)
        flags |= SDL_WINDOW_RESIZABLE;
    else
        flags |= SDL_WINDOW_BORDERLESS;

    _window = SDL_CreateWindow("Poseidon [Metal]", width, height, flags);
    if (!_window)
    {
        LOG_ERROR(Graphics, "Metal: SDL_CreateWindow failed: {}", SDL_GetError());
        return false;
    }
    if (!windowed)
    {
        SDL_SetWindowFullscreenMode(_window, nullptr);
        SDL_SetWindowFullscreen(_window, true);
    }

    _m->device = MTLCreateSystemDefaultDevice();
    if (!_m->device)
    {
        LOG_ERROR(Graphics, "Metal: MTLCreateSystemDefaultDevice returned nil");
        return false;
    }
    _m->queue = [_m->device newCommandQueue];

    _m->sem = dispatch_semaphore_create(MetalState::kRingCount);
    for (int i = 0; i < MetalState::kRingCount; i++)
        _m->ring[i] = [_m->device newBufferWithLength:MetalState::kRingBytes
                                              options:MTLResourceStorageModeShared];

    _m->view = SDL_Metal_CreateView(_window);
    if (!_m->view)
    {
        LOG_ERROR(Graphics, "Metal: SDL_Metal_CreateView failed: {}", SDL_GetError());
        return false;
    }
    _m->layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(_m->view);
    _m->layer.device = _m->device;
    _m->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _m->layer.framebufferOnly = NO; // we blit into the drawable

    // Backing pixel size (HighDPI): render at native resolution.
    int pw = width, ph = height;
    SDL_GetWindowSizeInPixels(_window, &pw, &ph);
    _w = pw;
    _h = ph;
    _m->layer.drawableSize = CGSizeMake(pw, ph);

    LOG_INFO(Graphics, "Metal: device '{}' — surface {}x{}", [[_m->device name] UTF8String], _w, _h);

    if (!LoadShaders(_m))
        LOG_ERROR(Graphics, "Metal: shader load failed — rendering will be clear-only");

    // Dev overlay (ImGui) — device + window are ready.  Mirrors EngineGL33::Init;
    // the overlay gates its own visibility on --dev and renders in Present().
    Dev::DebugOverlay::Init(_window, this);
    return true;
}

void EngineMetal::DestroyMetal()
{
    if (!_m)
        return;
    LOG_INFO(Graphics, "Metal: Destroying engine");
    Dev::DebugOverlay::Shutdown(); // before the device/queue go away
    _m->frameTex = nil;
    _m->cmd = nil;
    _m->queue = nil;
    _m->device = nil;
    _m->layer = nil;
    if (_m->view)
    {
        SDL_Metal_DestroyView(_m->view);
        _m->view = nullptr;
    }
    if (_window)
    {
        SDL_DestroyWindow(_window);
        _window = nullptr;
    }
}

static void EnsureFrameTex(MetalState* m, int w, int h)
{
    if (!m->frameTex || m->texW != w || m->texH != h)
    {
        MTLTextureDescriptor* d =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared; // unified memory: CPU-readable for screenshots
        m->frameTex = [m->device newTextureWithDescriptor:d];
        m->texW = w;
        m->texH = h;
        m->msaaColor = nil; // size changed -> rebuild the MSAA target too
        m->msaaW = m->msaaH = 0;
    }

    // Multisample colour target (resolves into frameTex on store).
    if (m->sampleCount > 1 && (!m->msaaColor || m->msaaW != w || m->msaaH != h))
    {
        MTLTextureDescriptor* md =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        md.textureType = MTLTextureType2DMultisample;
        md.sampleCount = m->sampleCount;
        md.usage = MTLTextureUsageRenderTarget;
        md.storageMode = MTLStorageModePrivate;
        m->msaaColor = [m->device newTextureWithDescriptor:md];
        m->msaaW = w;
        m->msaaH = h;
    }
    else if (m->sampleCount <= 1)
    {
        m->msaaColor = nil;
    }
}

// Configure a render pass's colour/depth/stencil attachments, MSAA-aware.  When
// multisampling, the scene renders into msaaColor and resolves into frameTex on
// store (StoreAndMultisampleResolve keeps the samples so a mid-frame Clear() pass
// can Load and continue while frameTex stays resolved for present/screenshots).
static void SetupPassAttachments(MTLRenderPassDescriptor* rp, MetalState* m, MTLLoadAction colorLoad,
                                 MTLLoadAction depthStencilLoad, MTLClearColor clearColor)
{
    const bool msaa = (m->sampleCount > 1 && m->msaaColor != nil);
    if (msaa)
    {
        rp.colorAttachments[0].texture = m->msaaColor;
        rp.colorAttachments[0].resolveTexture = m->frameTex;
        rp.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
    }
    else
    {
        rp.colorAttachments[0].texture = m->frameTex;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    rp.colorAttachments[0].loadAction = colorLoad;
    rp.colorAttachments[0].clearColor = clearColor;

    rp.depthAttachment.texture = m->depthTex;
    rp.depthAttachment.loadAction = depthStencilLoad;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.depthAttachment.clearDepth = 1.0;
    rp.stencilAttachment.texture = m->depthTex;
    rp.stencilAttachment.loadAction = depthStencilLoad;
    rp.stencilAttachment.storeAction = MTLStoreActionStore;
    rp.stencilAttachment.clearStencil = 0;
}

void EngineMetal::InitDraw(bool clear, PackedColor color)
{
    if (_frameOpen || !_m || !_m->device)
        return;

    // Track live backing size (window may have resized).
    int pw = _w, ph = _h;
    if (_window)
        SDL_GetWindowSizeInPixels(_window, &pw, &ph);
    if (pw > 0 && ph > 0)
    {
        _w = pw;
        _h = ph;
        _m->layer.drawableSize = CGSizeMake(pw, ph);
    }
    // SSAA: render targets are renderScale x the drawable; the scene renders at
    // this size and is downsampled to the window on present.
    const int rw = (int)lround((double)_m->renderScale * _w);
    const int rh = (int)lround((double)_m->renderScale * _h);
    EnsureFrameTex(_m, rw, rh);
    if (!_m->depthTex || _m->depthW != rw || _m->depthH != rh ||
        (int)_m->depthTex.sampleCount != (_m->sampleCount < 1 ? 1 : _m->sampleCount))
    {
        const int sc = _m->sampleCount < 1 ? 1 : _m->sampleCount;
        MTLTextureDescriptor* dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kDepthStencilFormat
                                                                                     width:rw
                                                                                    height:rh
                                                                                 mipmapped:NO];
        if (sc > 1)
        {
            dd.textureType = MTLTextureType2DMultisample;
            dd.sampleCount = sc;
        }
        dd.usage = MTLTextureUsageRenderTarget;
        dd.storageMode = MTLStorageModePrivate;
        _m->depthTex = [_m->device newTextureWithDescriptor:dd];
        _m->depthW = rw;
        _m->depthH = rh;
    }

    const float r = ((color >> 16) & 0xFF) / 255.0f;
    const float g = ((color >> 8) & 0xFF) / 255.0f;
    const float b = (color & 0xFF) / 255.0f;

    // Throttle to kRingCount frames in flight; pick this frame's ring buffer.
    dispatch_semaphore_wait(_m->sem, DISPATCH_TIME_FOREVER);
    _m->curRing = _m->ring[_m->frameCount % MetalState::kRingCount];
    _m->ringUsed = 0;

    _m->cmd = [_m->queue commandBuffer];

    // Spotlight shadow map: render the casters captured during the PREVIOUS frame
    // (the geometry is only known mid-frame, but this depth pass must precede the
    // main pass that samples it — so it's deferred one frame).  _shadowValid gates
    // both this frame's sampling and the dir.w=2 flag set in UploadLocalLights.
    _shadowValid = _shadowCastPending && !_m->casters.empty();
    if (_shadowValid)
    {
        // _cameraPos here is still last frame's value (BuildFrameConstants updates
        // it during the upcoming main pass) — i.e. the camera the deferred casters
        // and light matrix are relative to.
        _shadowCamPos[0] = _cameraPos[0];
        _shadowCamPos[1] = _cameraPos[1];
        _shadowCamPos[2] = _cameraPos[2];
        RenderSpotShadowMap();
    }
    else
    {
        memset(_vsShadow + VSlot::SpotVP * 4, 0, 64); // zero matrix -> SampleSpotShadow early-outs to lit
    }
    _shadowCastPending = false;
    _m->casters.clear();

    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    SetupPassAttachments(rp, _m, clear ? MTLLoadActionClear : MTLLoadActionLoad, MTLLoadActionClear,
                         MTLClearColorMake(r, g, b, 1.0));

    // Persistent per-frame render encoder; draw calls record into it until Present.
    _m->enc = [_m->cmd renderCommandEncoderWithDescriptor:rp];
    MTLViewport vp = {0.0, 0.0, (double)_m->texW, (double)_m->texH, 0.0, 1.0};
    [_m->enc setViewport:vp];

    _frameConstantsBuilt = false; // rebuild 3D frame constants lazily this frame
    // Sun is on at frame start; the shadow pass toggles it off/on mid-frame.
    // (EnableSunLight(false) must not leak across frames -> unlit world.)
    _sunEnabled = true;
    _vsShadow[VSlot::SunEn * 4] = 1.0f;

    Engine::InitDraw();
    _frameOpen = true;
}

void EngineMetal::Clear(bool clearZ, bool clearColor, PackedColor color)
{
    // Mid-frame clear (e.g. the in-game options notebook / vehicle interiors
    // clear depth before drawing 3D-in-UI content so it overlays the scene
    // without the first-person weapon poking through).  Metal can't clear an
    // attachment mid-encoder, so end the current encoder and start a new pass
    // that loads the existing colour (unless also clearing it) and clears depth.
    if (!_m || !_m->cmd || !_frameOpen || (!clearZ && !clearColor))
        return;
    if (_m->enc)
    {
        [_m->enc endEncoding];
        _m->enc = nil;
    }

    const float r = ((color >> 16) & 0xFF) / 255.0f;
    const float g = ((color >> 8) & 0xFF) / 255.0f;
    const float b = (color & 0xFF) / 255.0f;
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    SetupPassAttachments(rp, _m, clearColor ? MTLLoadActionClear : MTLLoadActionLoad,
                         clearZ ? MTLLoadActionClear : MTLLoadActionLoad, MTLClearColorMake(r, g, b, 1.0));

    _m->enc = [_m->cmd renderCommandEncoderWithDescriptor:rp];
    MTLViewport vp = {0.0, 0.0, (double)_m->texW, (double)_m->texH, 0.0, 1.0};
    [_m->enc setViewport:vp];
}

void EngineMetal::FinishDraw()
{
    if (_frameOpen)
    {
        Engine::FinishDraw();
        // FPS overlay (--fps) + viewer help text, drawn as the last 2D pass
        // while the encoder is still open.  Mirrors EngineGL33::FinishDraw —
        // without this call the overlay never renders on the Metal path.
        DrawFinishTexts();
        _frameOpen = false;
    }
}

void EngineMetal::NextFrame()
{
    Present();
    Engine::NextFrame();
}

void EngineMetal::Present()
{
    if (!_m || !_m->cmd)
        return;

    if (_m->enc)
    {
        [_m->enc endEncoding];
        _m->enc = nil;
    }

    // Dev overlay: composite ImGui into the resolved scene target (frameTex)
    // before the present blit — so it both shows on screen and lands in
    // screenshots (which read frameTex), matching the GL33 path.  Rendered at
    // frameTex resolution; under SSAA (renderScale>1) the UI is supersampled
    // with the scene, which is fine.
    if (_m->imguiReady && _m->frameTex)
    {
        MTLRenderPassDescriptor* orp = [MTLRenderPassDescriptor renderPassDescriptor];
        orp.colorAttachments[0].texture = _m->frameTex;
        orp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        orp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> oe = [_m->cmd renderCommandEncoderWithDescriptor:orp];
        _m->overlayPassDesc = orp;
        _m->overlayEnc = oe;
        Dev::DebugOverlay::NewFrame(); // builds the UI + ImGui_ImplMetal/SDL3 NewFrame
        Dev::DebugOverlay::Render();   // ImGui::Render + RenderDrawData into oe
        [oe endEncoding];
        _m->overlayEnc = nil;
        _m->overlayPassDesc = nil;
    }

    id<CAMetalDrawable> drawable = [_m->layer nextDrawable];
    if (drawable)
    {
        const bool sameSize = (_m->texW == (int)drawable.texture.width && _m->texH == (int)drawable.texture.height);
        if (sameSize)
        {
            // 1:1 — a plain blit copy (no SSAA downscale needed).
            id<MTLBlitCommandEncoder> blit = [_m->cmd blitCommandEncoder];
            [blit copyFromTexture:_m->frameTex
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(_m->texW, _m->texH, 1)
                        toTexture:drawable.texture
                 destinationSlice:0
                 destinationLevel:0
                destinationOrigin:MTLOriginMake(0, 0, 0)];
            [blit endEncoding];
        }
        else if (_m->psoBlit)
        {
            // SSAA: fullscreen draw samples the larger frameTex (linear) into the
            // window-size drawable, averaging the supersampled pixels down.
            MTLRenderPassDescriptor* brp = [MTLRenderPassDescriptor renderPassDescriptor];
            brp.colorAttachments[0].texture = drawable.texture;
            brp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            brp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> be = [_m->cmd renderCommandEncoderWithDescriptor:brp];
            [be setRenderPipelineState:_m->psoBlit];
            [be setFragmentTexture:_m->frameTex atIndex:0];
            [be setFragmentSamplerState:_m->samplers[SamplerIdx(true, true, false)] atIndex:0]; // clamp+linear
            [be drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [be endEncoding];
        }
        [_m->cmd presentDrawable:drawable];
    }

    // Release this frame's ring slot once the GPU is done reading it.
    dispatch_semaphore_t sem = _m->sem;
    [_m->cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
        dispatch_semaphore_signal(sem);
    }];

    const bool wantShot = _pendingScreenshotPath.GetLength() > 0;
    [_m->cmd commit];
    if (wantShot)
    {
        [_m->cmd waitUntilCompleted];
        CaptureScreenshotIfPending();
    }
    _m->cmd = nil;
    _m->curRing = nil;
    _m->frameCount++;
}

void EngineMetal::FlushPendingScreenshot()
{
    CaptureScreenshotIfPending();
}

void EngineMetal::CaptureScreenshotIfPending()
{
    if (_pendingScreenshotPath.GetLength() == 0 || !_m || !_m->frameTex)
        return;
    RString path = _pendingScreenshotPath;
    _pendingScreenshotPath = "";

    const int w = _m->texW;
    const int h = _m->texH;
    if (w <= 0 || h <= 0)
        return;

    std::vector<uint8_t> bgra((size_t)w * h * 4);
    [_m->frameTex getBytes:bgra.data()
              bytesPerRow:(NSUInteger)w * 4
               fromRegion:MTLRegionMake2D(0, 0, w, h)
              mipmapLevel:0];

    // BGRA8 (top-left origin) -> RGB top-down (no Y-flip needed; Metal is top-left).
    std::vector<uint8_t> rgb((size_t)w * h * 3);
    for (int i = 0; i < w * h; i++)
    {
        rgb[i * 3 + 0] = bgra[i * 4 + 2]; // R
        rgb[i * 3 + 1] = bgra[i * 4 + 1]; // G
        rgb[i * 3 + 2] = bgra[i * 4 + 0]; // B
    }
    ScreenshotWriter::WriteRGB(path, w, h, rgb.data());
    LOG_INFO(Graphics, "Metal: screenshot saved {}x{} -> {}", w, h, (const char*)path);
}

bool EngineMetal::SamplePixel(int x, int y, uint8_t* outRGB)
{
    // Read one pixel from the resolved scene target (frameTex, BGRA8, shared
    // storage, top-left origin).  x/y arrive in window pixels (the tri verb uses
    // Width()/Height()); frameTex may be renderScale x that, so map across.
    if (!_m || !_m->frameTex || !outRGB)
        return false;
    if (_w <= 0 || _h <= 0 || x < 0 || y < 0 || x >= _w || y >= _h)
        return false;
    int fx = (int)((double)x * _m->texW / _w);
    int fy = (int)((double)y * _m->texH / _h);
    if (fx >= _m->texW)
        fx = _m->texW - 1;
    if (fy >= _m->texH)
        fy = _m->texH - 1;
    uint8_t bgra[4] = {0, 0, 0, 0};
    [_m->frameTex getBytes:bgra bytesPerRow:4 fromRegion:MTLRegionMake2D(fx, fy, 1, 1) mipmapLevel:0];
    outRGB[0] = bgra[2]; // R
    outRGB[1] = bgra[1]; // G
    outRGB[2] = bgra[0]; // B
    return true;
}

// ---- Window / events -------------------------------------------------------

void EngineMetal::HandleEvents()
{
    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        // Feed the dev overlay first; when its panel has keyboard/mouse focus,
        // swallow those events so typing in the console doesn't also drive the
        // game (mirrors the GL33 path's WantsKeyboard/WantsMouse gating).
        Dev::DebugOverlay::ProcessEvent(event);
        const bool imWantKbd = Dev::DebugOverlay::WantsKeyboard();
        const bool imWantMouse = Dev::DebugOverlay::WantsMouse();
        switch (event.type)
        {
            case SDL_EVENT_QUIT:
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                if (GApp)
                    GApp->m_closeRequest = true;
                break;
            case SDL_EVENT_WINDOW_FOCUS_GAINED:
                _focused = true;
                if (GApp)
                    GApp->m_appActive = true;
                if (_mouseGrab && _window)
                    SDL_SetWindowRelativeMouseMode(_window, true);
                break;
            case SDL_EVENT_WINDOW_FOCUS_LOST:
                _focused = false;
                if (GApp)
                    GApp->m_appActive = false;
                if (_window)
                    SDL_SetWindowRelativeMouseMode(_window, false); // release so the OS cursor is free
                break;
            case SDL_EVENT_KEY_DOWN:
                if (imWantKbd)
                    break;
                if (!event.key.repeat)
                    SDLInput_BufferKeyEvent(event.key.scancode, true, Foundation::GlobalTickCount());
                SDLInput_BufferUIKeyEvent(event.key.key, true);
                break;
            case SDL_EVENT_KEY_UP:
                if (imWantKbd)
                    break;
                SDLInput_BufferKeyEvent(event.key.scancode, false, Foundation::GlobalTickCount());
                SDLInput_BufferUIKeyEvent(event.key.key, false);
                break;
            case SDL_EVENT_TEXT_INPUT:
                if (imWantKbd)
                    break;
                SDLInput_BufferUICharEvent(event.text.text);
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EVENT_MOUSE_BUTTON_UP:
            {
                if (imWantMouse)
                    break;
                int btn = event.button.button - 1;
                if (btn == 1)
                    btn = 2;
                else if (btn == 2)
                    btn = 1;
                SDLInput_BufferMouseButton(btn, event.type == SDL_EVENT_MOUSE_BUTTON_DOWN);
                break;
            }
            case SDL_EVENT_MOUSE_MOTION:
                if (imWantMouse)
                    break;
                SDLInput_BufferMouseMotion(event.motion.xrel, event.motion.yrel);
                break;
            case SDL_EVENT_MOUSE_WHEEL:
                if (imWantMouse)
                    break;
                SDLInput_BufferMouseWheel(event.wheel.y);
                break;
            default:
                break;
        }
    }
}

bool EngineMetal::IsOpen() const
{
    return _window != nullptr;
}

void EngineMetal::SetMouseGrab(bool grab)
{
    // Only hold the relative-mouse grab while the window is focused — otherwise
    // the grab gets stranded when focus is lost and the player can't move on
    // return (mirrors SDLEventWindow::SetMouseGrab).
    _mouseGrab = grab;
    if (_window)
        SDL_SetWindowRelativeMouseMode(_window, grab && _focused);
}

bool EngineMetal::SwitchRes(int w, int h, int /*bpp*/)
{
    return true;
}

bool EngineMetal::SetSwapInterval(int interval)
{
    if (!_m || !_m->layer)
        return false;
    // CAMetalLayer.displaySyncEnabled: YES presents on the vertical blank
    // (vsync), NO presents as soon as the GPU is done (uncapped).  Engine
    // interval 0 = vsync off; 1 = on; -1 (adaptive) maps to on (no CAMetalLayer
    // adaptive mode).  Driven by the Options > Video > Vsync setting.
    _m->layer.displaySyncEnabled = (interval != 0);
    return true;
}

int EngineMetal::GetSwapInterval() const
{
    return (_m && _m->layer && !_m->layer.displaySyncEnabled) ? 0 : 1;
}

void EngineMetal::SetMsaaSamples(int samples)
{
    if (!_m || !_m->device)
        return;
    int s = (samples < 2) ? 1 : samples;
    // Clamp down to a device-supported count (Apple GPUs support 4; 8 on some).
    while (s > 1 && ![_m->device supportsTextureSampleCount:(NSUInteger)s])
        s = (s == 8) ? 4 : (s == 4 ? 2 : 1);
    if (s == _m->sampleCount)
        return;
    _m->sampleCount = s;
    BuildPipelines(_m, s);          // rasterSampleCount must match the new attachments
    _m->frameTex = nil;             // recreate frame/MSAA/depth targets at the new count
    _m->texW = _m->texH = 0;
    _m->msaaColor = nil;
    _m->msaaW = _m->msaaH = 0;
    _m->depthTex = nil;
    _m->depthW = _m->depthH = 0;
    LOG_INFO(Graphics, "Metal: MSAA {}x", s);
}

void EngineMetal::SetRenderScale(float scale)
{
    if (!_m)
        return;
    float s = scale < 0.5f ? 0.5f : (scale > 2.0f ? 2.0f : scale);
    if (s == _m->renderScale)
        return;
    _m->renderScale = s;
    _m->frameTex = nil; // recreate render targets at the new size next InitDraw
    _m->texW = _m->texH = 0;
    _m->msaaColor = nil;
    _m->msaaW = _m->msaaH = 0;
    _m->depthTex = nil;
    _m->depthW = _m->depthH = 0;
    LOG_INFO(Graphics, "Metal: render scale {}", s);
}

float EngineMetal::GetRenderScale() const
{
    return _m ? _m->renderScale : 1.0f;
}

void EngineMetal::SetAlphaToCoverage(bool enable)
{
    if (!_m || _m->alphaToCoverage == enable)
        return;
    _m->alphaToCoverage = enable;
    BuildPipelines(_m, _m->sampleCount); // A2C is a PSO property -> rebuild
}

bool EngineMetal::GetAlphaToCoverage() const
{
    return _m && _m->alphaToCoverage;
}

void EngineMetal::ListResolutions(FindArray<ResolutionInfo>& /*ret*/) {}
void EngineMetal::ListRefreshRates(FindArray<int>& /*ret*/) {}

RString EngineMetal::GetDebugName() const
{
    return "Metal";
}
RString EngineMetal::GetRendererName() const
{
    if (_m && _m->device)
        return RString([[_m->device name] UTF8String]);
    return "Metal";
}

AbstractTextBank* EngineMetal::TextBank()
{
    return _bank; // TextBankDummy : AbstractTextBank
}

void EngineMetal::ResetForRemount()
{
    if (_bank)
        _bank->ReleaseAllTextures();
}

// ---- 2D drawing (M2: geometry path; vertex-color via psFlat, textures TBD) ---

static inline void SetV(Poseidon::TLVertex& v, float x, float y, float z, float rhw, PackedColor c)
{
    v = Poseidon::TLVertex{};
    v.pos[0] = x;
    v.pos[1] = y;
    v.pos[2] = z;
    v.rhw = rhw;
    v.color = c;
    v.specular = PackedColor((DWORD)0xff000000);
}

void EngineMetal::Draw2D(const Draw2DPars& pars, const Rect2DAbs& rect, const Rect2DAbs& clip)
{
    if (!pars.mip.IsOK() || !_m || !_m->enc)
        return;
    float xBeg = rect.x, xEnd = rect.x + rect.w;
    float yBeg = rect.y, yEnd = rect.y + rect.h;
    const float xc = clip.x > 0 ? clip.x : 0, yc = clip.y > 0 ? clip.y : 0;
    const float xec = (clip.x + clip.w) < _w ? (clip.x + clip.w) : _w;
    const float yec = (clip.y + clip.h) < _h ? (clip.y + clip.h) : _h;
    if (xBeg < xc)
        xBeg = xc;
    if (xEnd > xec)
        xEnd = xec;
    if (yBeg < yc)
        yBeg = yc;
    if (yEnd > yec)
        yEnd = yec;
    if (xBeg >= xEnd || yBeg >= yEnd)
        return;

    Poseidon::TLVertex pos[4];
    SetV(pos[0], xBeg, yBeg, 0.5f, 1, pars.colorTL);
    SetV(pos[1], xEnd, yBeg, 0.5f, 1, pars.colorTR);
    SetV(pos[2], xEnd, yEnd, 0.5f, 1, pars.colorBR);
    SetV(pos[3], xBeg, yEnd, 0.5f, 1, pars.colorBL);
    pos[0].t0 = {pars.uTL, pars.vTL};
    pos[1].t0 = {pars.uTR, pars.vTR};
    pos[2].t0 = {pars.uBR, pars.vBR};
    pos[3].t0 = {pars.uBL, pars.vBL};

    auto* tm = static_cast<TextureMetal*>(pars.mip._texture);
    id<MTLTexture> tex = tm ? tm->MetalTexture() : nil;
    EmitUI(_m, pos, 4, tex ? _m->psoNormal : _m->psoFlat, tex, _w, _h);
}

void EngineMetal::DrawPoly(const MipInfo& mip, const Vertex2DPixel* vertices, int n, const Rect2DPixel& /*clipRect*/,
                           int /*specFlags*/)
{
    if (n < 3 || !_m || !_m->enc)
        return;
    const int maxN = 64;
    if (n > maxN)
        n = maxN;
    Poseidon::TLVertex gv[64];
    const float x2d = Left2D(), y2d = Top2D();
    for (int i = 0; i < n; i++)
    {
        SetV(gv[i], vertices[i].x + x2d, vertices[i].y + y2d, vertices[i].z, vertices[i].w, vertices[i].color);
        gv[i].t0 = {vertices[i].u, vertices[i].v};
    }
    auto* tm = static_cast<TextureMetal*>(mip._texture);
    id<MTLTexture> tex = tm ? tm->MetalTexture() : nil;
    EmitUI(_m, gv, n, tex ? _m->psoNormal : _m->psoFlat, tex, _w, _h);
}

void EngineMetal::DrawPoly(const MipInfo& mip, const Vertex2DAbs* vertices, int n, const Rect2DAbs& /*clipRect*/,
                           int /*specFlags*/)
{
    if (n < 3 || !_m || !_m->enc)
        return;
    const int maxN = 64;
    if (n > maxN)
        n = maxN;
    Poseidon::TLVertex gv[64];
    for (int i = 0; i < n; i++)
    {
        SetV(gv[i], vertices[i].x, vertices[i].y, vertices[i].z, vertices[i].w, vertices[i].color);
        gv[i].t0 = {vertices[i].u, vertices[i].v};
    }
    auto* tm = static_cast<TextureMetal*>(mip._texture);
    id<MTLTexture> tex = tm ? tm->MetalTexture() : nil;
    EmitUI(_m, gv, n, tex ? _m->psoNormal : _m->psoFlat, tex, _w, _h);
}

void EngineMetal::DrawLine(const Line2DAbs& line, PackedColor c0, PackedColor c1, const Rect2DAbs& /*clip*/)
{
    if (!_m || !_m->enc)
        return;
    // Render as a 1px-thick quad perpendicular to the line direction.
    float x0 = line.beg.x, y0 = line.beg.y, x1 = line.end.x, y1 = line.end.y;
    float dx = x1 - x0, dy = y1 - y0;
    float len = dx * dx + dy * dy;
    len = len > 0 ? 1.0f / __builtin_sqrtf(len) : 0;
    const float nx = -dy * len * 0.5f, ny = dx * len * 0.5f; // 1px half-width normal
    Poseidon::TLVertex q[4];
    SetV(q[0], x0 + nx, y0 + ny, 0.5f, 1, c0);
    SetV(q[1], x1 + nx, y1 + ny, 0.5f, 1, c1);
    SetV(q[2], x1 - nx, y1 - ny, 0.5f, 1, c1);
    SetV(q[3], x0 - nx, y0 - ny, 0.5f, 1, c0);
    EmitUI(_m, q, 4, _m->psoFlat, nil, _w, _h);
}

// ---- 2D TLVertexTable soup path (UI / options notebook) --------------------
// BeginMesh hands us a screen-space TLVertex array; PrepareTriangle sets the
// current texture; DrawPolygon/DrawSection draw indexed triangle fans into it.
// Mirrors EngineGL33's AddVertices + QueuePrepareTriangle + QueueFan, but emits
// each fan immediately through the same EmitPolyFan path as Draw2D/DrawPoly.

void EngineMetal::BeginMesh(TLVertexTable& mesh, const render::LegacySpec& /*spec*/)
{
    if (!_m)
        return;
    _m->soupVerts = mesh.VertexData();
    _m->soupCount = mesh.NVertex();
    _m->soupTex = nil;
    // Defaults until the first PrepareTriangle: depth-tested + repeat (terrain).
    _m->soupDepth = _m->dss3D;
    _m->soupSampler = _m->samplers[SamplerIdx(false, false, false)];
}

void EngineMetal::EndMesh(TLVertexTable& /*mesh*/)
{
    if (!_m)
        return;
    _m->soupVerts = nullptr;
    _m->soupCount = 0;
    _m->soupTex = nil;
}

void EngineMetal::PrepareTriangle(const MipInfo& mip, int specFlags)
{
    if (!_m)
        return;
    auto* tm = static_cast<TextureMetal*>(mip._texture);
    _m->soupTex = tm ? tm->MetalTexture() : nil;

    // Pick depth + sampler from the spec so depth-tested 3D content (terrain via
    // LandscapeRender) integrates with the z-buffer, while NoZBuf 2D UI (the
    // options notebook) draws on top without a depth test.
    const render::LegacySpec spec = render::SplitLegacy((unsigned)specFlags);
    const bool noZBuf = render::Has(spec.backend, render::Backend::NoZBuf);
    const bool noZWrite = render::Has(spec.backend, render::Backend::NoZWrite);
    // Honour the spec's depth mode.  Interface 3D models (the campaign book, the
    // options notebook) need real depth so their own pages self-occlude; they
    // overlay the 3D scene because the UI container clears depth first (Clear()),
    // not by disabling depth here.
    _m->soupDepth = noZBuf ? _m->dss2D : (noZWrite ? _m->dss3DNoWrite : _m->dss3D);

    const bool clampU = render::Has(spec.backend, render::Backend::ClampU);
    const bool clampV = render::Has(spec.backend, render::Backend::ClampV);
    const bool point = render::Has(spec.backend, render::Backend::PointSampling);
    _m->soupSampler = _m->samplers[SamplerIdx(clampU, clampV, point)];
}

void EngineMetal::DrawPolygon(const VertexIndex* ii, int n)
{
    if (!_m || !_m->enc || !_m->soupVerts || n < 3)
        return;
    constexpr int kMaxFan = 256;
    if (n > kMaxFan)
        n = kMaxFan;
    Poseidon::TLVertex fan[kMaxFan];
    for (int i = 0; i < n; i++)
    {
        const int idx = ii[i];
        if (idx < 0 || idx >= _m->soupCount)
            return; // malformed index list — skip the whole fan
        fan[i] = _m->soupVerts[idx];
    }
    id<MTLTexture> tex = _m->soupTex;
    EmitPolyFan(_m, fan, n, tex ? _m->psoNormal : _m->psoFlat, tex, _w, _h, _m->soupDepth, _m->soupSampler);
}

void EngineMetal::DrawSection(const FaceArray& face, Offset beg, Offset end)
{
    if (!_m || !_m->soupVerts)
        return;
    for (Offset i = beg; i < end; face.Next(i))
    {
        const Poly& f = face[i];
        DrawPolygon(f.GetVertexList(), f.N());
    }
}

// ---- 3D mesh path (M3) -----------------------------------------------------

namespace
{
struct MetalSVertex
{
    Vector3P pos;
    Vector3P norm;
    Poseidon::UVPair t0;
};
struct MeshSection
{
    int beg, end;
};
} // namespace

class VertexBufferMetal : public VertexBuffer
{
  public:
    id<MTLDevice> device = nil;
    id<MTLBuffer> vbo = nil;
    id<MTLBuffer> ibo = nil;
    int vertexCount = 0;
    int indexCount = 0;
    bool _dynamic = false; // created VBDynamic/VBSmallDiscardable -> re-upload every frame
    std::vector<MeshSection> sections;

    // Pack the shape's current positions/normals/UVs into our interleaved
    // SVertex layout.  Animation mutates only positions/normals (topology, UVs
    // and section ranges are stable), so Update() reuses this for re-upload.
    static void BuildVertices(const Shape& src, std::vector<MetalSVertex>& out)
    {
        const int nv = src.NVertex();
        out.resize((size_t)nv);
        for (int i = 0; i < nv; i++)
        {
            const Vector3& p = src.Pos(i);
            const Vector3& n = src.Norm(i);
            out[i].pos = Vector3P(p.X(), p.Y(), p.Z());
            out[i].norm = Vector3P(-n.X(), -n.Y(), -n.Z()); // negated, matches GL/D3D11
            out[i].t0 = src.UV(i);
        }
    }

    bool Init(id<MTLDevice> dev, const Shape& src, VBType type)
    {
        const int nv = src.NVertex();
        if (nv <= 0)
            return false;
        device = dev;
        vertexCount = nv;
        _dynamic = (type == VBDynamic || type == VBSmallDiscardable);

        std::vector<MetalSVertex> verts;
        BuildVertices(src, verts);
        vbo = [dev newBufferWithBytes:verts.data()
                               length:verts.size() * sizeof(MetalSVertex)
                              options:MTLResourceStorageModeShared];

        // Fan-triangulate faces into 16-bit indices.
        std::vector<uint16_t> idx;
        for (Offset o = src.BeginFaces(); o < src.EndFaces(); src.NextFace(o))
        {
            const Poly& poly = src.Face(o);
            for (int i = 2; i < poly.N(); i++)
            {
                idx.push_back((uint16_t)poly.GetVertex(0));
                idx.push_back((uint16_t)poly.GetVertex(i - 1));
                idx.push_back((uint16_t)poly.GetVertex(i));
            }
        }
        indexCount = (int)idx.size();
        if (indexCount > 0)
            ibo = [dev newBufferWithBytes:idx.data()
                                   length:idx.size() * sizeof(uint16_t)
                                  options:MTLResourceStorageModeShared];

        // Per-section index ranges.
        const int ns = src.NSections();
        sections.resize(ns);
        int start = 0;
        for (int i = 0; i < ns; i++)
        {
            const ShapeSection& sec = src.GetSection(i);
            int size = 0;
            for (Offset o = sec.beg; o < sec.end; src.NextFace(o))
            {
                const Poly& face = src.Face(o);
                size += (face.N() - 2) * 3;
            }
            sections[i].beg = start;
            sections[i].end = start + size;
            start += size;
        }
        return true;
    }

    // Re-upload animated vertices each frame (mirrors VertexBufferGL33::Update).
    // Without this, characters freeze in their bind pose and proxy-attached
    // weapons stay at the model origin.  A fresh buffer per update is safe with
    // frames in flight: ARC + the command buffer keep the previous buffer alive
    // until its GPU work completes.
    void Update(const Shape& src, bool dynamic) override
    {
        // Mirror VertexBufferGL33::Update: re-upload when the buffer was created
        // dynamic, when this draw is flagged dynamic, or when the engine marked
        // the vertices dirty (InvalidateBuffer).  The body mesh is created
        // VBDynamic but its per-draw `dynamic` flag can be false, so gating only
        // on `dynamic` froze characters while their proxy weapons still moved.
        if (!(_dynamic || dynamic || bufferDirty) || !device || vertexCount <= 0)
            return;
        if (src.NVertex() != vertexCount)
            return; // topology changed unexpectedly — keep the existing buffer
        std::vector<MetalSVertex> verts;
        BuildVertices(src, verts);
        vbo = [device newBufferWithBytes:verts.data()
                                  length:verts.size() * sizeof(MetalSVertex)
                                 options:MTLResourceStorageModeShared];
        bufferDirty = false;
    }
};

VertexBuffer* EngineMetal::CreateVertexBuffer(const Shape& src, VBType type)
{
    auto* buf = new VertexBufferMetal();
    if (buf->Init(_m->device, src, type))
        return buf;
    delete buf;
    return nullptr;
}

static void Mat4MulRM(float* out, const float* a, const float* b); // defined below
static void UploadMat4(float* reg, const float* Tstd);

void EngineMetal::BuildFrameConstants()
{
    if (_frameConstantsBuilt || !GScene)
        return;
    Camera* cam = GScene->GetCamera();
    if (!cam)
        return;
    LightSun* sun = GScene->MainLight();

    GfxMatrix view;
    ConvertMatrix(view, cam->InverseScaled());
    view._41 = view._42 = view._43 = 0; // camera-relative
    memcpy(_vsShadow + VSlot::View * 4, &view, 64);

    GfxMatrix proj;
    ConvertProjectionMatrix(proj, cam->ProjectionNormal(), 0);
    memcpy(_vsShadow + VSlot::Proj * 4, &proj, 64);

    Vector3 pos = cam->Position();
    _cameraPos[0] = (float)pos.X();
    _cameraPos[1] = (float)pos.Y();
    _cameraPos[2] = (float)pos.Z();
    // Shaders operate in camera-relative space (world matrix has camPos subtracted);
    // GL33's UploadFrameConstants zeroes VS_CAMPOS so fog dist = length(worldPos).
    float cp[4] = {0, 0, 0, 0};
    memcpy(_vsShadow + VSlot::CamPos * 4, cp, 16);

    // Spotlight shadow sampling matrix.  The shadow map was rendered (at InitDraw)
    // relative to last frame's camera (_shadowCamPos), but this frame's fragments
    // are relative to _cameraPos.  Pre-translate world positions by the camera
    // delta so the lookup lands in the map's space: reg = (lightVP * Translate(d)).
    if (_shadowValid)
    {
        const float d[3] = {_cameraPos[0] - _shadowCamPos[0], _cameraPos[1] - _shadowCamPos[1],
                            _cameraPos[2] - _shadowCamPos[2]};
        const float tr[16] = {1, 0, 0, d[0], 0, 1, 0, d[1], 0, 0, 1, d[2], 0, 0, 0, 1};
        float m[16];
        Mat4MulRM(m, _lightVPstd, tr); // _lightVPstd is still last frame's here (set before SetMaterial runs)
        UploadMat4(_vsShadow + VSlot::SpotVP * 4, m);
    }

    Vector3 dir = sun ? sun->Direction() : Vector3(0, -1, 0);
    float sd[4] = {(float)dir.X(), (float)dir.Y(), (float)dir.Z(), 0};
    memcpy(_vsShadow + VSlot::SunDir * 4, sd, 16);

    // sunEn is owned by EnableSunLight + the per-frame reset in InitDraw — don't
    // clobber it here (the shadow pass toggles it off/on mid-frame).

    float fStart = cam->ClipNear(), fEnd = cam->ClipFar();
    fStart = GScene->GetFogMinRange();
    fEnd = GScene->GetFogMaxRange();
    float inv = (fEnd > fStart) ? 1.0f / (fEnd - fStart) : 0.0f;
    float fp[4] = {fStart, inv, 1.0f, 0};
    memcpy(_vsShadow + VSlot::Fog * 4, fp, 16);

    float tc[4] = {0, 0, 0, 0};
    memcpy(_vsShadow + VSlot::TexCtrl * 4, tc, 16); // no texgen

    ColorVal fog = FogColor();
    float fc[4] = {fog.R(), fog.G(), fog.B(), 1.0f};
    memcpy(_psShadow + PSlot::FogColor * 4, fc, 16);

    _frameConstantsBuilt = true;
}

void EngineMetal::UpdateProjection()
{
    if (!GScene || !GScene->GetCamera())
        return;
    GfxMatrix proj;
    ConvertProjectionMatrix(proj, GScene->GetCamera()->ProjectionNormal(), 0);
    memcpy(_vsShadow + VSlot::Proj * 4, &proj, 64);
}

void EngineMetal::EnableSunLight(bool enable)
{
    _sunEnabled = enable;
    float se[4] = {enable ? 1.0f : 0.0f, 0, 0, 0};
    memcpy(_vsShadow + VSlot::SunEn * 4, se, 16);
}

void EngineMetal::SetMaterial(const TLMaterial& mat, const LightList& lights, const render::LegacySpec& /*spec*/)
{
    auto wr = [&](int slot, const Color& c) {
        float v[4] = {c.R(), c.G(), c.B(), c.A()};
        memcpy(_vsShadow + slot * 4, v, 16);
    };

    // Modulate the material by the sun's diffuse/ambient colours (mirrors
    // EngineGL33::UploadVSMaterialConstants).  Without this the scene ignores the
    // time-of-day sun colour and always renders at full daylight brightness.
    LightSun* sun = GScene ? GScene->MainLight() : nullptr;
    const Color sunDif = sun ? sun->Diffuse() : Color(HWhite);
    const Color sunAmb = sun ? sun->Ambient() : Color(HWhite);
    const Color dif = sunDif * mat.diffuse;
    const Color amb = sunAmb * mat.ambient + sunDif * mat.forcedDiffuse;

    wr(VSlot::Ambient, amb);
    wr(VSlot::Diffuse, dif);
    wr(VSlot::Emissive, mat.emmisive); // raw
    const Color specCol = sunDif * mat.specular;
    float spec[4] = {specCol.R(), specCol.G(), specCol.B(), (float)mat.specularPower};
    memcpy(_vsShadow + VSlot::Spec * 4, spec, 16);
    float specEn[4] = {mat.specularPower > 0 ? 1.0f : 0.0f, 0, 0, 0};
    memcpy(_vsShadow + VSlot::SpecEn * 4, specEn, 16);

    UploadLocalLights(lights, mat, sun ? sun->NightEffect() : 0.0f);
}

// Row-major 4x4 multiply: out = a * b (standard math, applied as out * v).
static void Mat4MulRM(float* out, const float* a, const float* b)
{
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
        {
            float s = 0;
            for (int k = 0; k < 4; k++)
                s += a[r * 4 + k] * b[k * 4 + c];
            out[r * 4 + c] = s;
        }
}

// Write reg[0..3] = transpose(Tstd): mat4At loads reg rows as MSL columns, so a
// standard (row-major, M*v) matrix must be transposed to round-trip as M.
static void UploadMat4(float* reg, const float* Tstd)
{
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            reg[i * 4 + j] = Tstd[j * 4 + i];
}

// Build the shadow-casting spot's view-projection from its camera-relative pose
// and stash it (mat4At upload form) in _lightVPpending for next frame's depth
// pass + this-coupled sampling.
void EngineMetal::BuildSpotLightMatrix(const float eye[3], const float dirIn[3], float range)
{
    float d[3] = {dirIn[0], dirIn[1], dirIn[2]};
    float dl = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
    if (dl < 1e-6f)
    {
        d[0] = 0;
        d[1] = 0;
        d[2] = 1;
        dl = 1;
    }
    d[0] /= dl;
    d[1] /= dl;
    d[2] /= dl;
    float up[3] = {0, 1, 0};
    if (fabsf(d[1]) > 0.95f) // beam near-vertical: pick a different up
    {
        up[0] = 0;
        up[1] = 0;
        up[2] = 1;
    }

    // RH look-at (view looks down -Z): s = right, u = up, f = forward(d).
    float s[3] = {d[1] * up[2] - d[2] * up[1], d[2] * up[0] - d[0] * up[2], d[0] * up[1] - d[1] * up[0]};
    float sl = sqrtf(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
    if (sl < 1e-6f)
        sl = 1;
    s[0] /= sl;
    s[1] /= sl;
    s[2] /= sl;
    float u[3] = {s[1] * d[2] - s[2] * d[1], s[2] * d[0] - s[0] * d[2], s[0] * d[1] - s[1] * d[0]};
    float V[16] = {s[0],  s[1],  s[2],  -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]),
                   u[0],  u[1],  u[2],  -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]),
                   -d[0], -d[1], -d[2], (d[0] * eye[0] + d[1] * eye[1] + d[2] * eye[2]),
                   0,     0,     0,     1};

    // RH perspective, Metal NDC z in [0,1]; square map (aspect 1).
    const float fovY = 0.72f; // ~41 deg — covers the lit cone (~24 deg) + penumbra
    const float zn = 0.25f;
    float zf = range * 8.0f;
    if (zf < 20.0f)
        zf = 20.0f;
    const float ys = 1.0f / tanf(fovY * 0.5f);
    const float xs = ys; // aspect 1
    float P[16] = {xs, 0, 0, 0, 0, ys, 0, 0, 0, 0, zf / (zn - zf), zn * zf / (zn - zf), 0, 0, -1, 0};

    // Standard (row-major, M*v) light view-projection; transposed to upload form
    // only when written to a reg slot.  Kept in standard form so the sampling
    // matrix can be post-multiplied by the camera-delta translation.
    Mat4MulRM(_lightVPstd, P, V); // T = P * V
    _shadowCastPending = true;
}

// Depth-only pass: replay the previous frame's captured opaque geometry from the
// flashlight's viewpoint into _m->spotShadowTex.  Encoded at frame start (before
// the main pass) so the main pass can sample it.
void EngineMetal::RenderSpotShadowMap()
{
    if (!_m || !_m->cmd || !_m->spotShadowTex || !_m->psoSpotDepth || _m->casters.empty())
        return;

    // The depth-pass VS reads reg[66..69]; bind the (untranslated) light matrix
    // we captured the casters with.  The main-pass sampling matrix gets the
    // camera-delta correction added later in BuildFrameConstants.
    UploadMat4(_vsShadow + VSlot::SpotVP * 4, _lightVPstd);

    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = _m->spotShadowTex;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.depthAttachment.clearDepth = 1.0;

    id<MTLRenderCommandEncoder> enc = [_m->cmd renderCommandEncoderWithDescriptor:rp];
    MTLViewport vp = {0, 0, (double)MetalState::kSpotShadowSize, (double)MetalState::kSpotShadowSize, 0, 1};
    [enc setViewport:vp];
    [enc setRenderPipelineState:_m->psoSpotDepth];
    [enc setDepthStencilState:_m->dssSpotDepth];
    [enc setCullMode:MTLCullModeNone];
    [enc setVertexBytes:_vsShadow length:sizeof(_vsShadow) atIndex:1];
    bool dynBias = false; // track current bias so we only switch it when it changes
    [enc setDepthBias:2.0f slopeScale:3.0f clamp:0.0f];
    for (const ShadowCaster& c : _m->casters)
    {
        if (!c.vbo || !c.ibo || c.indexCount <= 0)
            continue;
        // Animated casters lag one frame (the depth pass is deferred), so their
        // moved silhouette self-shadows; push them back harder to hide the acne
        // at the cost of a slightly detached (peter-panned) shadow.
        if (c.dynamic != dynBias)
        {
            dynBias = c.dynamic;
            if (dynBias)
                [enc setDepthBias:4.0f slopeScale:8.0f clamp:0.0f];
            else
                [enc setDepthBias:2.0f slopeScale:3.0f clamp:0.0f];
        }
        [enc setVertexBuffer:c.vbo offset:0 atIndex:0];
        [enc setVertexBytes:c.world length:64 atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:c.indexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:c.ibo
                 indexBufferOffset:(NSUInteger)c.firstIndex * sizeof(uint16_t)];
    }
    [enc endEncoding];
}

// Per-vertex point/spot lights (lamps, headlights), gated by NightEffect and
// camera-relative to match the shaders' camera-relative world space.  Mirrors
// EngineGL33::UploadVSLights.
void EngineMetal::UploadLocalLights(const LightList& lights, const TLMaterial& mat, float nightEffect)
{
    int n = 0;
    bool builtSpotShadow = false; // only the first spot drives the (single) shadow map
    if (nightEffect > 0.0f)
    {
        const Color matDif = mat.diffuse * nightEffect;
        const Color matAmb = mat.ambient * nightEffect;
        for (int i = 0; i < lights.Size() && n < VSlot::MaxLocalLights; i++)
        {
            Light* light = lights[i];
            if (!light)
                continue;
            LightDescription desc;
            light->GetDescription(desc);
            const bool isSpot = desc.type == LTSpotLight;
            if (desc.type != LTPoint && !isSpot)
                continue; // point + spot only; the sun is the directional term

            float* p = _vsShadow + (VSlot::LightPos + n) * 4;
            p[0] = desc.pos.X() - _cameraPos[0];
            p[1] = desc.pos.Y() - _cameraPos[1];
            p[2] = desc.pos.Z() - _cameraPos[2];
            p[3] = desc.startAtten;

            Vector3 beam = desc.dir;
            beam.Normalize();
            float* dir = _vsShadow + (VSlot::LightDir + n) * 4;
            dir[0] = beam.X();
            dir[1] = beam.Y();
            dir[2] = beam.Z();
            // Spot dir.w: 1 = plain spot, 2 = shadow-casting spot (sampled this
            // frame).  The first spot builds the shadow matrix for next frame;
            // it's flagged shadow-casting only once the map is actually populated.
            float spotFlag = isSpot ? 1.0f : 0.0f;
            if (isSpot && !builtSpotShadow)
            {
                BuildSpotLightMatrix(p, dir, desc.startAtten);
                builtSpotShadow = true;
                if (_shadowValid)
                    spotFlag = 2.0f;
            }
            dir[3] = spotFlag;

            // Spot cone half-angles (cos^2), packed into the otherwise-unused .w
            // of diffuse (inner) / ambient (outer): the shader fades the cone
            // from full inside the inner angle to zero at the outer.  desc.theta /
            // phi come from the light (LightReflector), so the lit cone matches
            // the engine's reported cone instead of a hardcoded constant.  0 for
            // point lights (cone unused there).
            float innerC2 = 0.0f, outerC2 = 0.0f;
            if (isSpot)
            {
                const float ci = cosf(desc.theta), co = cosf(desc.phi);
                innerC2 = ci * ci;
                outerC2 = co * co;
            }

            const Color ld = desc.diffuse * matDif;
            float* df = _vsShadow + (VSlot::LightDiffuse + n) * 4;
            df[0] = ld.R();
            df[1] = ld.G();
            df[2] = ld.B();
            df[3] = innerC2;

            const Color la = desc.ambient * matAmb;
            float* am = _vsShadow + (VSlot::LightAmbient + n) * 4;
            am[0] = la.R();
            am[1] = la.G();
            am[2] = la.B();
            am[3] = outerC2;

            n++;
        }
    }
    float lc[4] = {(float)n, 0, 0, 0};
    memcpy(_vsShadow + VSlot::LightCount * 4, lc, 16);
}

void EngineMetal::FogColorChanged(const Color& c)
{
    float v[4] = {c.R(), c.G(), c.B(), 1.0f};
    memcpy(_psShadow + PSlot::FogColor * 4, v, 16);
}

void EngineMetal::PrepareTriangleTL(const MipInfo& mip, const render::LegacySpec& spec)
{
    auto* tm = static_cast<TextureMetal*>(mip._texture);
    id<MTLTexture> tex = tm ? tm->MetalTexture() : nil;
    _m->meshTex = tex ? tex : _m->fallbackWhiteTex;
    _meshSpec = spec;
}

void EngineMetal::PrepareMeshTL(const LightList& /*lights*/, const Matrix4& modelToWorld, const render::LegacySpec&)
{
    BuildFrameConstants();
    GfxMatrix world;
    ConvertMatrix(world, modelToWorld);
    world._41 -= _cameraPos[0];
    world._42 -= _cameraPos[1];
    world._43 -= _cameraPos[2];
    // Stash this mesh's world matrix; DrawSectionTL uploads it per-draw via
    // setVertexBytes.  A single shared worldUBO slot would be overwritten by the
    // NEXT object's PrepareMeshTL before the GPU executes this object's draws
    // (all draws recorded into one command buffer read the buffer at execution
    // time) — collapsing every object onto the last object's transform.
    memcpy(_curWorld, &world, 64);
}

void EngineMetal::BeginMeshTL(const Shape& sMesh, int /*spec*/, bool dynamic)
{
    // Re-upload animated meshes from their current (CPU-skinned) vertices.
    // Mirrors EngineGL33::BeginMeshTL — without it, characters freeze in bind
    // pose and proxy weapons render at the model origin.
    if (VertexBuffer* vb = sMesh.GetVertexBuffer())
        vb->Update(sMesh, dynamic);
}
void EngineMetal::EndMeshTL(const Shape& /*sMesh*/) {}

// Detail draws sample tex1 at uv0*32 (mirrors GL33 TGDetail: texCtrl.y=1,
// texMat1 = diag(32,32,32,1)).  Written every draw so non-detail draws reset it.
void EngineMetal::ApplyDetailTexgen(bool detail)
{
    float* texCtrl = _vsShadow + VSlot::TexCtrl * 4;
    if (detail)
    {
        texCtrl[0] = 0.0f;
        texCtrl[1] = 1.0f;
        texCtrl[2] = 0.0f;
        texCtrl[3] = 0.0f;
        float* texMat1 = _vsShadow + VSlot::TexMat1 * 4;
        memset(texMat1, 0, 16 * sizeof(float));
        texMat1[0] = texMat1[5] = texMat1[10] = 32.0f;
        texMat1[15] = 1.0f;
    }
    else
    {
        texCtrl[0] = texCtrl[1] = texCtrl[2] = texCtrl[3] = 0.0f;
    }
}

void EngineMetal::DrawSectionTL(const Shape& sMesh, int beg, int end)
{
    if (!_m || !_m->enc)
        return;
    auto* buf = static_cast<VertexBufferMetal*>(sMesh.GetVertexBuffer());
    if (!buf || buf->sections.empty() || !buf->vbo || !buf->ibo)
        return;
    if (end <= beg || end > (int)buf->sections.size())
        return;

    const int firstIndex = buf->sections[beg].beg;
    const int indexCount = buf->sections[end - 1].end - firstIndex;
    if (indexCount <= 0)
        return;

    render::BuildContext ctx;
    ctx.isIn3DPass = true;
    const render::RenderPassDescriptor passDesc = render::BuildRenderPassDescriptor(_meshSpec, ctx);
    const bool alphaTest = passDesc.alpha != render::AlphaMode::Disabled;
    float alphaRef[4] = {passDesc.alphaRef / 255.0f, alphaTest ? 1.0f : 0.0f, 0.0f, 0.0f};
    memcpy(_psShadow + PSlot::AlphaRef * 4, alphaRef, 16);

    id<MTLTexture> tex = _m->meshTex;

    // Terrain (and other multitextured surfaces) flag Backend::DetailTexture; GL33
    // binds a single global detail texture to unit 1 and runs psDetail, with the
    // detail UV scaled 32x (TGDetail texgen).  Without it terrain shows only the
    // smooth base texture -> blurry.  Fall back to psNormal if the detail texture
    // is unavailable.
    id<MTLTexture> detailTex = (tex && render::Has(_meshSpec.backend, render::Backend::DetailTexture) && _bank)
                                   ? _bank->DetailMetalTexture()
                                   : nil;
    const bool detail = detailTex != nil;
    ApplyDetailTexgen(detail);

    const bool isShadow = passDesc.shader == render::ShaderFamily::Shadow;
    const bool useBlend = passDesc.blend != render::BlendMode::Opaque || passDesc.alpha == render::AlphaMode::Blend ||
                          passDesc.alpha == render::AlphaMode::TestAndBlend;
    const bool noZWrite = passDesc.depth == render::DepthMode::ReadOnly || passDesc.depth == render::DepthMode::Disabled;

    id<MTLRenderPipelineState> pso;
    id<MTLDepthStencilState> dss;
    if (isShadow)
    {
        pso = _m->psoMeshShadow;
        dss = _m->dssShadow; // LEQUAL no-write + stencil EQUAL 0 / INCR
    }
    else
    {
        pso = !tex       ? _m->psoMeshFlat
              : detail   ? _m->psoMeshDetail
              : useBlend ? _m->psoMeshBlend
                         : _m->psoMesh;
        dss = noZWrite ? _m->dss3DNoWrite : _m->dss3D;
    }
    // Capture opaque solid geometry as a shadow caster for next frame's spot
    // shadow map.  Skip projected-shadow polys, translucent surfaces, and
    // depth-read-only passes — none should occlude the flashlight beam.
    if (!isShadow && !useBlend && !noZWrite)
    {
        ShadowCaster sc;
        sc.vbo = buf->vbo;
        sc.ibo = buf->ibo;
        sc.firstIndex = firstIndex;
        sc.indexCount = indexCount;
        sc.dynamic = buf->_dynamic; // animated -> extra shadow bias (one-frame lag)
        memcpy(sc.world, _curWorld, 64);
        _m->casters.push_back(sc);
    }

    [_m->enc setRenderPipelineState:pso];
    [_m->enc setDepthStencilState:dss];
    [_m->enc setStencilReferenceValue:0]; // shadow EQUAL-0 / non-shadow REPLACE-0 reference

    // Depth bias: shadows are projected onto the (uneven) terrain — a large
    // angle-independent offset keeps them winning the LEQUAL test without acne
    // (mirrors GL33 glPolygonOffset(-1,-64)).  Roads/decals use a smaller offset
    // (glPolygonOffset(-1,-1)).  Reset to 0 otherwise (encoder state sticks).
    if (isShadow)
        [_m->enc setDepthBias:-64.0f slopeScale:-1.0f clamp:0.0f];
    else if (passDesc.surface == render::SurfaceMode::OnSurface)
        [_m->enc setDepthBias:-1.0f slopeScale:-1.0f clamp:0.0f];
    else
        [_m->enc setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    [_m->enc setCullMode:MTLCullModeNone];
    [_m->enc setVertexBuffer:buf->vbo offset:0 atIndex:0];
    [_m->enc setVertexBytes:_vsShadow length:sizeof(_vsShadow) atIndex:1];
    [_m->enc setVertexBytes:_curWorld length:64 atIndex:2]; // per-draw world matrix (WorldInstances[0])
    if (tex)
    {
        const bool point = passDesc.sampler.filter == render::SamplerFilter::Point;
        id<MTLSamplerState> samp = _m->samplers[SamplerIdx(passDesc.sampler.clampU, passDesc.sampler.clampV, point)];
        [_m->enc setFragmentBytes:_psShadow length:sizeof(_psShadow) atIndex:1];
        [_m->enc setFragmentBytes:_vsShadow length:sizeof(_vsShadow) atIndex:2]; // VS constants for per-pixel lighting
        [_m->enc setFragmentTexture:tex atIndex:0];
        [_m->enc setFragmentSamplerState:samp atIndex:0];
        // Spotlight shadow map (texture/sampler 2): always bound for psNormalLit/
        // psDetailLit; when no flashlight is active the matrix is zeroed so the
        // shader early-outs without sampling.
        [_m->enc setFragmentTexture:_m->spotShadowTex atIndex:2];
        [_m->enc setFragmentSamplerState:_m->shadowSampler atIndex:2];
        if (detail)
        {
            // Detail texture always tiles (uv0*32) — force the repeat sampler.
            [_m->enc setFragmentTexture:detailTex atIndex:1];
            [_m->enc setFragmentSamplerState:_m->samplers[SamplerIdx(false, false, point)] atIndex:1];
        }
    }
    [_m->enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:indexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:buf->ibo
                 indexBufferOffset:(NSUInteger)firstIndex * sizeof(uint16_t)];
}

// --- Dev-overlay ImGui backend (Metal) --------------------------------------
// Mirrors EngineGL33's hooks (imgui_impl_metal + SDL3-for-Metal). NewFrame and
// RenderDrawData run inside the Present overlay pass, where overlayPassDesc /
// overlayEnc are live (see Present()).

bool EngineMetal::OverlayBackendInit(SDL_Window* window)
{
    if (!_m || !_m->device)
        return false;
    if (!ImGui_ImplSDL3_InitForMetal(window))
    {
        LOG_ERROR(Graphics, "EngineMetal: ImGui_ImplSDL3_InitForMetal failed");
        return false;
    }
    if (!ImGui_ImplMetal_Init(_m->device))
    {
        LOG_ERROR(Graphics, "EngineMetal: ImGui_ImplMetal_Init failed");
        ImGui_ImplSDL3_Shutdown();
        return false;
    }
    _m->imguiReady = true;
    return true;
}

void EngineMetal::OverlayBackendShutdown()
{
    if (!_m || !_m->imguiReady)
        return;
    ImGui_ImplMetal_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    _m->imguiReady = false;
}

void EngineMetal::OverlayBackendNewFrame()
{
    if (!_m || !_m->imguiReady || !_m->overlayPassDesc)
        return;
    ImGui_ImplMetal_NewFrame(_m->overlayPassDesc);
    ImGui_ImplSDL3_NewFrame();
}

void EngineMetal::OverlayBackendRender()
{
    if (!_m || !_m->imguiReady || !_m->overlayEnc || !_m->cmd)
        return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), _m->cmd, _m->overlayEnc);
}

Engine* CreateEngineMetal(int w, int h, bool windowed, int bpp)
{
    return new EngineMetal(w, h, windowed, bpp);
}

// Backend-available probe used by the factory descriptor (GraphicsBackendMetal.cpp).
bool MetalBackendAvailable()
{
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    return dev != nil;
}

} // namespace Poseidon
