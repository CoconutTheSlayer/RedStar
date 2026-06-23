#include <PoseidonMetal/EngineMetal.hpp>
#include <PoseidonMetal/EngineFactoryMetal.hpp>

#include <Poseidon/Graphics/Dummy/TextBankDummy.hpp>
#include <Poseidon/Graphics/Shared/ScreenshotWriter.hpp>
#include <Poseidon/Graphics/Core/TLVertex.hpp>
#include <Poseidon/Core/Application.hpp>
#include <Poseidon/Foundation/Framework/AppFrame.hpp>
#include <Poseidon/Foundation/Framework/Log.hpp>

#include <cstddef> // offsetof

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_metal.h>

#include <vector>

// Shared SDL input buffers (InputProcessing_sdl.cpp) — same handlers GL33/Dummy use.
extern void SDLInput_BufferKeyEvent(SDL_Scancode sc, bool down, DWORD timestamp);
extern void SDLInput_BufferMouseButton(int btn, bool down);
extern void SDLInput_BufferMouseMotion(float dx, float dy);
extern void SDLInput_BufferMouseWheel(float dy);
extern void SDLInput_BufferUIKeyEvent(SDL_Keycode key, bool down);
extern void SDLInput_BufferUICharEvent(const char* text);

namespace Poseidon
{

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

    // Shaders / pipeline (M2 spine)
    id<MTLLibrary> lib = nil;
    id<MTLRenderPipelineState> psoFlat = nil;   // vsScreen + psFlat
    id<MTLRenderPipelineState> psoNormal = nil; // vsScreen + psNormal
    id<MTLSamplerState> samplerLinear = nil;

    // Triple-buffered dynamic vertex ring for 2D immediate-mode geometry.
    static constexpr int kRingCount = 3;
    static constexpr size_t kRingBytes = 4 * 1024 * 1024; // ~100k TLVertex
    id<MTLBuffer> ring[kRingCount] = {nil, nil, nil};
    dispatch_semaphore_t sem = nil;
    uint64_t frameCount = 0;
    id<MTLBuffer> curRing = nil;
    size_t ringUsed = 0;
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

static id<MTLRenderPipelineState> MakePSO(id<MTLDevice> dev, id<MTLLibrary> lib, const char* vsName,
                                          const char* psName, MTLPixelFormat colorFmt, bool blend)
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
    pd.vertexDescriptor = MakeTLVertexDescriptor();
    pd.colorAttachments[0].pixelFormat = colorFmt;
    if (blend)
    {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pso)
        LOG_ERROR(Graphics, "Metal: PSO ({}/{}) failed: {}", vsName, psName,
                  err ? [[err localizedDescription] UTF8String] : "?");
    return pso;
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

    m->psoFlat = MakePSO(m->device, m->lib, "vsScreen", "psFlat", MTLPixelFormatBGRA8Unorm, true);
    m->psoNormal = MakePSO(m->device, m->lib, "vsScreen", "psNormal", MTLPixelFormatBGRA8Unorm, true);

    MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeRepeat;
    m->samplerLinear = [m->device newSamplerStateWithDescriptor:sd];

    LOG_INFO(Graphics, "Metal: shaders loaded (psoFlat={}, psoNormal={})", m->psoFlat != nil, m->psoNormal != nil);
    return m->psoFlat != nil;
}

// Fan-triangulate n screen-space TLVertices into the current ring buffer and
// draw them via the given pipeline. tex==nil uses vertex color only (psFlat);
// a non-nil texture binds tex0+sampler for psNormal.
static void EmitPolyFan(MetalState* m, const Poseidon::TLVertex* v, int n, id<MTLRenderPipelineState> pso,
                        id<MTLTexture> tex, int w, int h)
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
    vsConst[21 * 4 + 0] = 2.0f / w;
    vsConst[21 * 4 + 1] = 2.0f / h;

    [m->enc setRenderPipelineState:pso];
    [m->enc setVertexBuffer:m->curRing offset:m->ringUsed atIndex:0];
    [m->enc setVertexBytes:vsConst length:sizeof(vsConst) atIndex:1];
    if (tex)
    {
        [m->enc setFragmentTexture:tex atIndex:0];
        [m->enc setFragmentSamplerState:m->samplerLinear atIndex:0];
    }
    [m->enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:triVerts];

    m->ringUsed += need;
}

EngineMetal::EngineMetal(int width, int height, bool windowed, int bpp)
{
    _w = width;
    _h = height;
    _pixelSize = bpp > 0 ? bpp : 32;
    _windowed = windowed;
    _bank = new TextBankDummy();
    _m = new MetalState();

    if (!CreateWindowAndDevice(width, height, windowed))
        LOG_ERROR(Graphics, "Metal: initialization failed");
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
    return true;
}

void EngineMetal::DestroyMetal()
{
    if (!_m)
        return;
    LOG_INFO(Graphics, "Metal: Destroying engine");
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
    if (m->frameTex && m->texW == w && m->texH == h)
        return;
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
    EnsureFrameTex(_m, _w, _h);

    const float r = ((color >> 16) & 0xFF) / 255.0f;
    const float g = ((color >> 8) & 0xFF) / 255.0f;
    const float b = (color & 0xFF) / 255.0f;

    // Throttle to kRingCount frames in flight; pick this frame's ring buffer.
    dispatch_semaphore_wait(_m->sem, DISPATCH_TIME_FOREVER);
    _m->curRing = _m->ring[_m->frameCount % MetalState::kRingCount];
    _m->ringUsed = 0;

    _m->cmd = [_m->queue commandBuffer];

    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = _m->frameTex;
    rp.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, 1.0);

    // Persistent per-frame render encoder; 2D draw calls record into it until Present.
    _m->enc = [_m->cmd renderCommandEncoderWithDescriptor:rp];
    MTLViewport vp = {0.0, 0.0, (double)_w, (double)_h, 0.0, 1.0};
    [_m->enc setViewport:vp];

    Engine::InitDraw();
    _frameOpen = true;
}

void EngineMetal::Clear(bool /*clearZ*/, bool /*clear*/, PackedColor /*color*/)
{
    // M1: clearing is handled by InitDraw's render pass loadAction.
}

void EngineMetal::FinishDraw()
{
    if (_frameOpen)
    {
        Engine::FinishDraw();
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

    id<CAMetalDrawable> drawable = [_m->layer nextDrawable];
    if (drawable)
    {
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

// ---- Window / events -------------------------------------------------------

void EngineMetal::HandleEvents()
{
    SDL_Event event;
    while (SDL_PollEvent(&event))
    {
        switch (event.type)
        {
            case SDL_EVENT_QUIT:
            case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                if (GApp)
                    GApp->m_closeRequest = true;
                break;
            case SDL_EVENT_KEY_DOWN:
                if (!event.key.repeat)
                    SDLInput_BufferKeyEvent(event.key.scancode, true, Foundation::GlobalTickCount());
                SDLInput_BufferUIKeyEvent(event.key.key, true);
                break;
            case SDL_EVENT_KEY_UP:
                SDLInput_BufferKeyEvent(event.key.scancode, false, Foundation::GlobalTickCount());
                SDLInput_BufferUIKeyEvent(event.key.key, false);
                break;
            case SDL_EVENT_TEXT_INPUT:
                SDLInput_BufferUICharEvent(event.text.text);
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EVENT_MOUSE_BUTTON_UP:
            {
                int btn = event.button.button - 1;
                if (btn == 1)
                    btn = 2;
                else if (btn == 2)
                    btn = 1;
                SDLInput_BufferMouseButton(btn, event.type == SDL_EVENT_MOUSE_BUTTON_DOWN);
                break;
            }
            case SDL_EVENT_MOUSE_MOTION:
                SDLInput_BufferMouseMotion(event.motion.xrel, event.motion.yrel);
                break;
            case SDL_EVENT_MOUSE_WHEEL:
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
    if (_window)
        SDL_SetWindowRelativeMouseMode(_window, grab);
}

bool EngineMetal::SwitchRes(int w, int h, int /*bpp*/)
{
    return true;
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
    EmitPolyFan(_m, pos, 4, _m->psoFlat, nil, _w, _h);
}

void EngineMetal::DrawPoly(const MipInfo& /*mip*/, const Vertex2DPixel* vertices, int n,
                           const Rect2DPixel& /*clipRect*/, int /*specFlags*/)
{
    if (n < 3 || !_m || !_m->enc)
        return;
    const int maxN = 64;
    if (n > maxN)
        n = maxN;
    Poseidon::TLVertex gv[64];
    const float x2d = Left2D(), y2d = Top2D();
    for (int i = 0; i < n; i++)
        SetV(gv[i], vertices[i].x + x2d, vertices[i].y + y2d, vertices[i].z, vertices[i].w, vertices[i].color);
    EmitPolyFan(_m, gv, n, _m->psoFlat, nil, _w, _h);
}

void EngineMetal::DrawPoly(const MipInfo& /*mip*/, const Vertex2DAbs* vertices, int n, const Rect2DAbs& /*clipRect*/,
                           int /*specFlags*/)
{
    if (n < 3 || !_m || !_m->enc)
        return;
    const int maxN = 64;
    if (n > maxN)
        n = maxN;
    Poseidon::TLVertex gv[64];
    for (int i = 0; i < n; i++)
        SetV(gv[i], vertices[i].x, vertices[i].y, vertices[i].z, vertices[i].w, vertices[i].color);
    EmitPolyFan(_m, gv, n, _m->psoFlat, nil, _w, _h);
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
    EmitPolyFan(_m, q, 4, _m->psoFlat, nil, _w, _h);
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
