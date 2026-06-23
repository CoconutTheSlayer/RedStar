#pragma once

// TextureMetal / TextBankMetal — Metal texture + bank.
//
// Strategy: report no DXT/compressed support, so every mip's destination format
// is set to PacARGB8888. The shared PAA/PAC decoder (ITextureSource) then expands
// DXT and all packed formats to 32-bit BGRA at GetMipmapData() time — no
// GPU-side decompression needed (Apple Silicon Metal has no BC formats anyway).
// Upload is one MTLPixelFormatBGRA8Unorm texture per source, all mips resident
// (no streaming/LRU — fine for this era of game on unified-memory Macs).
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
    void ASetNMipmaps(int n) override { _nMipmaps = n; }
    Color GetPixel(int /*level*/, float /*u*/, float /*v*/) const override { return HBlack; }
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
    id<MTLDevice> _device = nil;

    int Find(RStringB name) const;

  public:
    explicit TextBankMetal(id<MTLDevice> dev) : _device(dev) {}

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
