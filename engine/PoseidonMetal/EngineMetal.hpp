#pragma once

#include <Poseidon/Graphics/Core/Engine.hpp>
#include <Poseidon/Foundation/Strings/RString.hpp>

// EngineMetal — native Metal rendering backend (Apple Silicon).
//
// M1 scope: opens an SDL3 window backed by a CAMetalLayer, clears it each frame,
// pumps events, and supports --auto-screenshot.  All geometry/texture entry
// points are no-op stubs for now (filled in M2+).  Public header is pure C++:
// every Objective-C / Metal object lives in the opaque MetalState defined inside
// EngineMetal.mm, so plain-C++ TUs (the factory registration) can include this.

struct SDL_Window;

namespace Poseidon
{
class TextBankMetal;
struct MetalState; // defined in EngineMetal.mm

class EngineMetal : public Engine
{
  private:
    MetalState* _m = nullptr; // all id<MTL...> / CAMetalLayer state (ObjC)
    SDL_Window* _window = nullptr;
    TextBankMetal* _bank = nullptr;

    int _w = 640;
    int _h = 480;
    int _pixelSize = 32;
    bool _windowed = true;
    bool _frameOpen = false;
    RString _pendingScreenshotPath;

    // CPU shadows of the VS/PS uniform blocks (mirror EngineGL33's s_vsShadow /
    // s_psShadow). 70 vec4 (VSConstants) + 27 vec4 (PSConstants).
    float _vsShadow[70 * 4] = {};
    float _psShadow[27 * 4] = {};
    float _cameraPos[3] = {}; // absolute camera position (world-matrix camera-relative shift)
    float _curWorld[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}; // per-mesh world matrix (set in PrepareMeshTL)
    bool _sunEnabled = true;
    bool _frameConstantsBuilt = false;
    render::LegacySpec _meshSpec = {};

  public:
    EngineMetal(int width, int height, bool windowed, int bpp);
    ~EngineMetal() override;

    // --- Identity ---
    RString GetDebugName() const override;
    RString GetRendererName() const override;

    // --- Frame lifecycle (real Metal) ---
    using Engine::InitDraw; // unhide base overload
    void InitDraw(bool clear, PackedColor color) override;
    void FinishDraw() override;
    void NextFrame() override;
    void Clear(bool clearZ, bool clear, PackedColor color) override;

    // --- Window / events (real) ---
    void HandleEvents() override;
    bool IsOpen() const override;
    void SetMouseGrab(bool grab) override;
    bool SetWindowMode(WindowMode mode) override { return true; }
    bool SwitchRes(int w, int h, int bpp) override;
    bool SwitchRefreshRate(int refresh) override { return true; }
    void ListResolutions(FindArray<ResolutionInfo>& ret) override;
    void ListRefreshRates(FindArray<int>& ret) override;

    int Width() const override { return _w; }
    int Height() const override { return _h; }
    int PixelSize() const override { return _pixelSize; }
    int RefreshRate() const override { return 0; }
    bool CanBeWindowed() const override { return true; }
    bool IsWindowed() const override { return _windowed; }
    bool IsResizable() const override { return false; }
    int AFrameTime() const override { return 0; }

    // --- Screenshots (real) ---
    void Screenshot(RString filename) override { _pendingScreenshotPath = filename; }
    void FlushPendingScreenshot() override;

    // --- Gamma / pause ---
    void Pause() override {}
    void Restore() override {}
    void SetGamma(float) override {}
    float GetGamma() const override { return 1.0f; }
    void FogColorChanged(const Color& c) override;

    // --- Texture bank (placeholder Dummy bank for M1) ---
    AbstractTextBank* TextBank() override;
    void TextureDestroyed(Texture*) override {}
    void ResetForRemount() override;

    // --- Depth / bias caps ---
    bool CanZBias() const override { return false; }
    bool ZBiasExclusion() const override { return false; }
    float ZShadowEpsilon() const override { return 0.01f; }
    float ZRoadEpsilon() const override { return 0.005f; }
    float ObjMipmapCoef() const override { return 1; }
    int GetBias() override { return 0; }
    void SetBias(int) override {}
    void GetZCoefs(float& zAdd, float& zMult) override { zAdd = 0, zMult = 1; }

    // --- 3D mesh path (M3) ---
    // Advertise hardware T&L so the engine routes geometry through the
    // PrepareMeshTL/DrawSectionTL path (implemented here) rather than the
    // software DrawPolygon path.
    bool GetTL() const override { return true; }
    bool GetTLOnSurface() const override { return true; }
    VertexBuffer* CreateVertexBuffer(const Shape& src, VBType type) override;
    void UpdateProjection() override;
    void EnableSunLight(bool enable) override;
    void SetMaterial(const TLMaterial& mat, const LightList& lights, const render::LegacySpec& spec) override;
    void PrepareTriangleTL(const MipInfo& mip, const render::LegacySpec& spec) override;
    void PrepareMeshTL(const LightList& lights, const Matrix4& modelToWorld, const render::LegacySpec& spec) override;
    void BeginMeshTL(const Shape& sMesh, int spec, bool dynamic) override;
    void EndMeshTL(const Shape& sMesh) override;
    void DrawSectionTL(const Shape& sMesh, int beg, int end) override;

    // --- Geometry / 2D submission: no-op stubs ---
    void PrepareMesh(const render::LegacySpec&) override {}
    void BeginMesh(TLVertexTable&, const render::LegacySpec&) override {}
    void EndMesh(TLVertexTable&) override {}
    void PrepareTriangle(const MipInfo&, int) override {}
    void DrawPolygon(const VertexIndex*, int) override {}
    void DrawSection(const FaceArray&, Offset, Offset) override {}
    void DrawDecal(Vector3Par, float, float, float, PackedColor, const MipInfo&, int) override {}
    using Engine::Draw2D; // unhide base overloads
    void Draw2D(const Draw2DPars&, const Rect2DAbs&, const Rect2DAbs&) override;
    void DrawLine(int, int) override {}
    void DrawLine(const Line2DAbs&, PackedColor, PackedColor, const Rect2DAbs&) override;
    void DrawPoly(const MipInfo&, const Vertex2DPixel*, int, const Rect2DPixel&, int) override;
    void DrawPoly(const MipInfo&, const Vertex2DAbs*, int, const Rect2DAbs&, int) override;

  private:
    // Implemented in EngineMetal.mm
    bool CreateWindowAndDevice(int width, int height, bool windowed);
    void DestroyMetal();
    void Present();
    void CaptureScreenshotIfPending();
    void BuildFrameConstants();
};

} // namespace Poseidon
