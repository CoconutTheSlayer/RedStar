#pragma once

// TextureMetal / TextBankMetal — Metal texture + bank.
//
// Strategy: mirror GL33's per-source DstFormat selection so the shared PAA/PAC
// decoder expands each format correctly (P8 -> ARGB1555, DXT -> ARGB8888, etc.).
// CPU upload always converts decoded pixels to MTLPixelFormatBGRA8Unorm — Metal
// has no BC/DXT formats on Apple Silicon.
//
// ObjC++ header: included only by .mm TUs in PoseidonMetal.

#include <Poseidon/Graphics/Textures/TextureBank.hpp>
#include <Poseidon/Graphics/Rendering/Font/Pactext.hpp> // ITextureSource, PacLevelMem, MAX_MIPMAPS, PacFormat
#include <Poseidon/Foundation/Types/Pointers.hpp>
#include <Poseidon/Foundation/Containers/Array.hpp>

#import <Metal/Metal.h>

namespace Poseidon
{

class TextureMetal : public Texture
{
    typedef Texture base;
    friend class TextBankMetal;

  public:
    SRef<ITextureSource> _src;
    PacLevelMem _mipmaps[MAX_MIPMAPS];
    int _nMipmaps = 0;
    int _maxSize = 0x10000;
    int _largestUsed = 0;
    bool _initialized = false;
    bool _uploaded = false;
    bool _dynamic = false; // CreateDynamic / font atlas (content in _tex, no _src)

    id<MTLDevice> _device = nil;
    id<MTLTexture> _tex = nil;

    explicit TextureMetal(id<MTLDevice> dev) : _device(dev) {}
    ~TextureMetal() override { _tex = nil; }

    int Init(const char* name);
    void DoLoadHeaders();
    void LoadHeadersNV()
    {
        if (!_initialized)
            DoLoadHeaders();
    }
    void EnsureUploaded(); // decode mips + upload to _tex (lazy)

    // Dynamic (raw RGBA, e.g. FreeType font atlas).
    bool InitFromRGBA(int w, int h, const void* rgba, uint32_t size, bool mipmap);
    void UpdateRGBA(const void* rgba, uint32_t size);

    // Returns the uploaded MTLTexture (uploads on first use).
    id<MTLTexture> MetalTexture()
    {
        EnsureUploaded();
        return _tex;
    }

    // --- Texture interface (decode-side, mirrors TextureGL33; GPU-agnostic) ---
    void LoadHeaders() override { LoadHeadersNV(); }
    void SetMaxSize(int size) override { _maxSize = size; }
    int AMaxSize() const override { return _maxSize; }
    int AWidth(int level = 0) const override
    {
        const_cast<TextureMetal*>(this)->LoadHeadersNV();
        return _mipmaps[level]._w;
    }
    int AHeight(int level = 0) const override
    {
        const_cast<TextureMetal*>(this)->LoadHeadersNV();
        return _mipmaps[level]._h;
    }
    int ANMipmaps() const override { return _nMipmaps; }
    AbstractMipmapLevel& AMipmap(int level) override { return _mipmaps[level]; }
    const AbstractMipmapLevel& AMipmap(int level) const override { return _mipmaps[level]; }
    void ASetNMipmaps(int n) override;
    Color GetPixel(int level, float u, float v) const override;
    bool IsTransparent() const override { return _src && _src->IsTransparent(); }
    Color GetColor() override
    {
        const_cast<TextureMetal*>(this)->LoadHeadersNV();
        return _src ? Color(_src->GetAverageColor()) : HBlack;
    }
    bool IsAlpha() const override { return _src && _src->IsAlpha(); }
    bool VerifyChecksum(const MipInfo&) const override { return true; }
};

class TextBankMetal : public AbstractTextBank
{
    RefArray<TextureMetal> _texture;
    Ref<TextureMetal> _detail; // global terrain detail texture (CfgDetailTextures>>"detail")
    bool _detailTried = false;
    id<MTLDevice> _device = nil;

    int Find(RStringB name) const;

  public:
    explicit TextBankMetal(id<MTLDevice> dev) : _device(dev) {}

    // Global detail texture, sampled at unit 1 by psDetail for terrain.  Loaded
    // and uploaded lazily on first use (mirrors TextBankGL33::InitDetailTextures).
    id<MTLTexture> DetailMetalTexture();

    Ref<Texture> Load(RStringB name) override;
    Ref<Texture> LoadInterpolated(RStringB n1, RStringB n2, float factor) override;
    int NTextures() const override { return _texture.Size(); }
    Texture* GetTexture(int i) const override { return _texture[i]; }
    MipInfo UseMipmap(Texture* texture, int level, int levelTop) override;
    void Compact() override {}
    void Preload() override {}
    void FlushTextures() override {}
    void FlushBank(QFBank*) override {}
    void ReleaseAllTextures() override { _texture.Clear(); }

    Texture* CreateDynamic(int w, int h, const void* rgba, uint32_t size, bool mipmap) override;
    void UpdateDynamic(Texture* tex, const void* rgba, uint32_t size) override;
};

} // namespace Poseidon
