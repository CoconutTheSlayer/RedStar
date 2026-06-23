#include <PoseidonMetal/TextureMetal.hpp>

#include <Poseidon/Graphics/Core/MipmapLayout.hpp>
#include <Poseidon/Graphics/Textures/LooseTextures.hpp>
#include <Poseidon/Core/Global.hpp>
#include <Poseidon/Core/Config/EngineConfig.hpp>
#include <Poseidon/Graphics/Core/Engine.hpp>
#include <Poseidon/IO/Streams/QBStream.hpp>
#include <Poseidon/IO/ParamFile/ParamFile.hpp>
#include <Poseidon/Foundation/Framework/Log.hpp>
#include <Poseidon/Foundation/Common/FltOpts.hpp>

extern ParamFile Remaster; // global config root (defined in the engine core)

#include <cstring>
#include <algorithm>
#include <vector>

#define MIN_MIP_SIZE 4 // matches the GL/decoder lower bound

namespace Poseidon
{

namespace
{

PacFormat BasicFormat(const char* name)
{
    const char* ext = strrchr(name, '.');
    if (ext && !strcmpi(ext, ".paa"))
        return PacARGB4444;
    return PacARGB1555;
}

PacFormat MetalDecodeFormat(PacFormat srcFormat)
{
    switch (srcFormat)
    {
        case PacDXT1:
        case PacDXT2:
        case PacDXT3:
        case PacDXT4:
        case PacDXT5:
            // Metal has no BC/DXT formats; CPU decompress via DecompressDXT1 writes
            // ARGB1555 words (see Pactext.cpp). Match GL33's non-DXT fallback.
            return PacARGB1555;
        case PacP8:
            return PacARGB1555;
        case PacAI88:
            return PacARGB8888;
        case PacARGB1555:
        case PacRGB565:
        case PacARGB4444:
        case PacARGB8888:
            return srcFormat;
        default:
            LOG_DEBUG(Graphics, "Metal: unsupported source format {}, falling back to ARGB1555", (int)srcFormat);
            return PacARGB1555;
    }
}

void ExpandDecodedToBGRA8(PacFormat fmt, const uint8_t* src, int w, int h, int srcPitch, uint8_t* dst)
{
    const int dstPitch = w * 4;
    switch (fmt)
    {
        case PacARGB8888:
            for (int y = 0; y < h; ++y)
                std::memcpy(dst + y * dstPitch, src + y * srcPitch, (size_t)dstPitch);
            break;
        case PacARGB1555:
            for (int y = 0; y < h; ++y)
            {
                const uint16_t* row = reinterpret_cast<const uint16_t*>(src + y * srcPitch);
                uint8_t* out = dst + y * dstPitch;
                for (int x = 0; x < w; ++x)
                {
                    const uint16_t p = row[x];
                    const uint8_t r = (p >> 10) & 0x1F;
                    const uint8_t g = (p >> 5) & 0x1F;
                    const uint8_t b = p & 0x1F;
                    out[x * 4 + 0] = (b << 3) | (b >> 2);
                    out[x * 4 + 1] = (g << 3) | (g >> 2);
                    out[x * 4 + 2] = (r << 3) | (r >> 2);
                    out[x * 4 + 3] = (p & 0x8000) ? 255 : 0;
                }
            }
            break;
        case PacRGB565:
            for (int y = 0; y < h; ++y)
            {
                const uint16_t* row = reinterpret_cast<const uint16_t*>(src + y * srcPitch);
                uint8_t* out = dst + y * dstPitch;
                for (int x = 0; x < w; ++x)
                {
                    const uint16_t p = row[x];
                    const uint8_t r = (p >> 11) & 0x1F;
                    const uint8_t g = (p >> 5) & 0x3F;
                    const uint8_t b = p & 0x1F;
                    out[x * 4 + 0] = (b << 3) | (b >> 2);
                    out[x * 4 + 1] = (g << 2) | (g >> 4);
                    out[x * 4 + 2] = (r << 3) | (r >> 2);
                    out[x * 4 + 3] = 255;
                }
            }
            break;
        case PacARGB4444:
            for (int y = 0; y < h; ++y)
            {
                const uint16_t* row = reinterpret_cast<const uint16_t*>(src + y * srcPitch);
                uint8_t* out = dst + y * dstPitch;
                for (int x = 0; x < w; ++x)
                {
                    const uint16_t p = row[x];
                    const uint8_t a = (p >> 12) & 0xF;
                    const uint8_t r = (p >> 8) & 0xF;
                    const uint8_t g = (p >> 4) & 0xF;
                    const uint8_t b = p & 0xF;
                    out[x * 4 + 0] = (b << 4) | b;
                    out[x * 4 + 1] = (g << 4) | g;
                    out[x * 4 + 2] = (r << 4) | r;
                    out[x * 4 + 3] = (a << 4) | a;
                }
            }
            break;
        default:
            LOG_ERROR(Graphics, "Metal: cannot expand decode format {} to BGRA8", (int)fmt);
            std::memset(dst, 0, (size_t)dstPitch * h);
            break;
    }
}

// FreeType / CreateDynamic supply RGBA byte order; Metal expects BGRA8.
void SwizzleRGBAToBGRA8(const uint8_t* rgba, int w, int h, uint8_t* bgra)
{
    const int n = w * h;
    for (int i = 0; i < n; ++i)
    {
        bgra[i * 4 + 0] = rgba[i * 4 + 2];
        bgra[i * 4 + 1] = rgba[i * 4 + 1];
        bgra[i * 4 + 2] = rgba[i * 4 + 0];
        bgra[i * 4 + 3] = rgba[i * 4 + 3];
    }
}

} // namespace

// ---- TextureMetal ----------------------------------------------------------

int TextureMetal::Init(const char* name)
{
    SetName(name);
    _maxSize = 0x10000;
    RString resolved = Poseidon::Graphics::ResolveLooseTexturePath(name);
    ITextureSourceFactory* factory = SelectTextureSourceFactory(resolved);
    if (!factory || !factory->Check(resolved))
    {
        _nMipmaps = 0;
        return -1;
    }
    return 0;
}

void TextureMetal::DoLoadHeaders()
{
    if (_initialized)
        return;
    _initialized = true;

    if (_maxSize >= 0x10000)
    {
        if (!CmpStartStr(Name(), "fonts\\"))
            _maxSize = 1024;
        else if (!CmpStartStr(Name(), "merged\\"))
            _maxSize = 2048;
        else if (GLOB_ENGINE && GLOB_ENGINE->TextBank() &&
                 GLOB_ENGINE->TextBank()->AnimatedNumber(Name()) >= 0 && IsAlpha())
            _maxSize = ENGINE_CONFIG.maxAnimText;
        else
            _maxSize = ENGINE_CONFIG.maxObjText;
    }

    RString resolved = Poseidon::Graphics::ResolveLooseTexturePath(Name());
    ITextureSourceFactory* factory = SelectTextureSourceFactory(resolved);
    if (!factory)
    {
        _nMipmaps = 0;
        return;
    }
    _src = factory->Create(resolved, _mipmaps, MAX_MIPMAPS);
    if (!_src)
    {
        _nMipmaps = 0;
        return;
    }

    PacFormat format = BasicFormat(Name());
    const bool isPaa = (format == PacARGB4444);

    format = _src->GetFormat();
    if (format == PacARGB4444 || format == PacAI88 || format == PacARGB8888)
        _src->ForceAlpha();

    PacFormat dFormat = MetalDecodeFormat(format);
    if (!_src->IsTransparent() && _src->GetFormat() == PacARGB1555 && !isPaa)
        dFormat = PacRGB565;

    _largestUsed = MAX_MIPMAPS;
    int n = _src->GetMipmapCount();
    int i = 0;
    for (i = 0; i < n; i++)
    {
        PacLevelMem& mip = _mipmaps[i];
        mip.SetDestFormat(dFormat, 8);
        if (!mip.TooLarge(_maxSize) && _largestUsed > i)
            _largestUsed = i;
        if (mip._w < MIN_MIP_SIZE || mip._h < MIN_MIP_SIZE)
            break;
    }
    _nMipmaps = i;
    if (_largestUsed >= _nMipmaps)
        _largestUsed = _nMipmaps > 0 ? _nMipmaps - 1 : 0;
}

void TextureMetal::EnsureUploaded()
{
    if (_uploaded || _dynamic)
        return;
    LoadHeadersNV();
    if (!_src || _nMipmaps <= 0)
        return;

    const int levelMin = _largestUsed;
    const int w0 = _mipmaps[levelMin]._w;
    const int h0 = _mipmaps[levelMin]._h;
    const int levels = _nMipmaps - levelMin;
    if (w0 <= 0 || h0 <= 0 || levels <= 0)
        return;

    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w0
                                                                                height:h0
                                                                             mipmapped:(levels > 1)];
    d.mipmapLevelCount = levels;
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    _tex = [_device newTextureWithDescriptor:d];

    std::vector<uint8_t> decodeBuf;
    std::vector<uint8_t> uploadBuf;
    for (int i = levelMin; i < _nMipmaps; i++)
    {
        PacLevelMem& mip = _mipmaps[i];
        const PacFormat mipFmt = mip.DstFormat();
        const auto decodeLayout = Poseidon::render::mipmap::ComputeLayout(mipFmt, mip._w, mip._h);
        // GetMipmapData lays the decoded pixels out tightly for the dest format
        // (no padding) — read them back at that same tight pitch, NOT mip._pitch
        // (which is the *source* pitch and would smear rows).
        const int srcPitch = decodeLayout.tightPitch;
        decodeBuf.assign((size_t)decodeLayout.dataSize, 0);
        if (!_src->GetMipmapData(decodeBuf.data(), mip, i))
        {
            LOG_WARN(Graphics, "Metal: cannot decode mip {} of {}", i, Name());
            std::memset(decodeBuf.data(), 0, decodeBuf.size());
        }

        const int bgraPitch = mip._w * 4;
        const size_t bgraSize = (size_t)bgraPitch * mip._h;
        uploadBuf.assign(bgraSize, 0);
        ExpandDecodedToBGRA8(mipFmt, decodeBuf.data(), mip._w, mip._h, srcPitch, uploadBuf.data());

        [_tex replaceRegion:MTLRegionMake2D(0, 0, mip._w, mip._h)
                mipmapLevel:(i - levelMin)
                  withBytes:uploadBuf.data()
                bytesPerRow:(NSUInteger)bgraPitch];
    }
    _uploaded = true;
}

bool TextureMetal::InitFromRGBA(int w, int h, const void* rgba, uint32_t size, bool mipmap)
{
    _dynamic = true;
    _initialized = true;
    _uploaded = true;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:mipmap];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    _tex = [_device newTextureWithDescriptor:d];
    if (!_tex)
        return false;
    if (rgba && size >= (uint32_t)(w * h * 4))
    {
        std::vector<uint8_t> bgra((size_t)w * h * 4);
        SwizzleRGBAToBGRA8(static_cast<const uint8_t*>(rgba), w, h, bgra.data());
        [_tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bgra.data()
                bytesPerRow:(NSUInteger)w * 4];
    }
    return true;
}

void TextureMetal::UpdateRGBA(const void* rgba, uint32_t size)
{
    if (!_tex || !rgba)
        return;
    const int w = (int)_tex.width, h = (int)_tex.height;
    if (size >= (uint32_t)(w * h * 4))
    {
        std::vector<uint8_t> bgra((size_t)w * h * 4);
        SwizzleRGBAToBGRA8(static_cast<const uint8_t*>(rgba), w, h, bgra.data());
        [_tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:bgra.data()
                bytesPerRow:(NSUInteger)w * 4];
    }
}

Color TextureMetal::GetPixel(int level, float u, float v) const
{
    const_cast<TextureMetal*>(this)->LoadHeadersNV();
    if (!_src || level < 0 || level >= _nMipmaps)
        return HBlack;

    PacLevelMem mip = _mipmaps[level];
    std::vector<uint8_t> mem((size_t)mip._pitch * mip._h, 0);
    if (!_src->GetMipmapData(mem.data(), mip, level))
        return HBlack;
    return mip.GetPixel(mem.data(), u, v);
}

void TextureMetal::ASetNMipmaps(int n)
{
    LoadHeadersNV();
    if (n > _nMipmaps)
    {
        LOG_ERROR(Graphics, "Out of range ASetNMipmaps in {}", static_cast<const char*>(Name()));
        n = _nMipmaps;
    }
    if (n <= 0)
        return;
    _nMipmaps = n;
    PacLevelMem& mip = _mipmaps[n - 1];
    saturateMax(_maxSize, mip._w);
    saturateMax(_maxSize, mip._h);
    if (_largestUsed > _nMipmaps - 1)
        _largestUsed = _nMipmaps - 1;
    if (_uploaded)
    {
        _uploaded = false;
        _tex = nil;
    }
}

// ---- TextBankMetal ---------------------------------------------------------

int TextBankMetal::Find(RStringB name) const
{
    for (int i = 0; i < _texture.Size(); i++)
        if (_texture[i] && _texture[i]->GetName() == name)
            return i;
    return -1;
}

Ref<Texture> TextBankMetal::Load(RStringB name)
{
    int i = Find(name);
    if (i >= 0)
        return _texture[i].GetRef();

    RString resolved = Poseidon::Graphics::ResolveLooseTexturePath(name);
    if (!QIFStreamB::FileExist(resolved))
        return nullptr;

    Ref<TextureMetal> texture = new TextureMetal(_device);
    if (!texture || texture->Init(name))
        return nullptr;

    int iFree = _texture.Size();
    _texture.Access(iFree);
    _texture[iFree] = texture;
    return texture.GetRef();
}

Ref<Texture> TextBankMetal::LoadInterpolated(RStringB n1, RStringB /*n2*/, float /*factor*/)
{
    return Load(n1);
}

id<MTLTexture> TextBankMetal::DetailMetalTexture()
{
    if (!_detail && !_detailTried)
    {
        _detailTried = true; // load once; if it fails, don't retry every draw
        const ParamEntry& names = Remaster >> "CfgDetailTextures";
        RStringB detailName = names >> "detail";
        if (QIFStreamB::FileExist(detailName))
        {
            Ref<TextureMetal> t = new TextureMetal(_device);
            if (t && t->Init(detailName) == 0)
                _detail = t;
        }
    }
    return _detail ? _detail->MetalTexture() : nil;
}

MipInfo TextBankMetal::UseMipmap(Texture* absTexture, int level, int top)
{
    if (!absTexture)
        return MipInfo(nullptr, 0);

    TextureMetal* texture = static_cast<TextureMetal*>(absTexture);
    texture->LoadHeadersNV();

    if (texture->_dynamic && texture->_tex)
        return MipInfo(texture, 0);

    if (level < 0)
        level = 0;
    saturateMin(level, texture->_nMipmaps - 1);
    saturateMax(top, texture->_largestUsed);
    saturateMin(top, level);
    saturateMax(level, top);

    texture->EnsureUploaded();
    return MipInfo(texture, level);
}

Texture* TextBankMetal::CreateDynamic(int w, int h, const void* rgba, uint32_t size, bool mipmap)
{
    Ref<TextureMetal> tex = new TextureMetal(_device);
    if (!tex->InitFromRGBA(w, h, rgba, size, mipmap))
        return nullptr;
    int iFree = _texture.Size();
    _texture.Access(iFree);
    _texture[iFree] = tex;
    return tex.GetRef();
}

void TextBankMetal::UpdateDynamic(Texture* tex, const void* rgba, uint32_t size)
{
    if (tex)
        static_cast<TextureMetal*>(tex)->UpdateRGBA(rgba, size);
}

} // namespace Poseidon
