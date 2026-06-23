#include <PoseidonMetal/TextureMetal.hpp>

#include <Poseidon/Graphics/Core/MipmapLayout.hpp>
#include <Poseidon/Graphics/Textures/LooseTextures.hpp>
#include <Poseidon/IO/Streams/QBStream.hpp>
#include <Poseidon/Foundation/Framework/Log.hpp>

#include <vector>

#define MIN_MIP_SIZE 4 // matches the GL/decoder lower bound

namespace Poseidon
{

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
        else
            _maxSize = 2048;
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

    PacFormat srcFormat = _src->GetFormat();
    if (srcFormat == PacARGB4444 || srcFormat == PacAI88 || srcFormat == PacARGB8888)
        _src->ForceAlpha();

    // Universal expansion to 32-bit BGRA — the decoder unpacks DXT/packed
    // formats for us, so the GPU only ever sees MTLPixelFormatBGRA8Unorm.
    _largestUsed = MAX_MIPMAPS;
    int n = _src->GetMipmapCount();
    int i = 0;
    for (i = 0; i < n; i++)
    {
        PacLevelMem& mip = _mipmaps[i];
        mip.SetDestFormat(PacARGB8888, 8);
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

    std::vector<uint8_t> buf;
    for (int i = levelMin; i < _nMipmaps; i++)
    {
        PacLevelMem& mip = _mipmaps[i];
        const auto layout = Poseidon::render::mipmap::ComputeLayout(PacARGB8888, mip._w, mip._h);
        buf.assign((size_t)layout.dataSize, 0);
        _src->GetMipmapData(buf.data(), mip, i);
        [_tex replaceRegion:MTLRegionMake2D(0, 0, mip._w, mip._h)
                mipmapLevel:(i - levelMin)
                  withBytes:buf.data()
                bytesPerRow:(NSUInteger)layout.tightPitch];
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
        [_tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)w * 4];
    return true;
}

void TextureMetal::UpdateRGBA(const void* rgba, uint32_t size)
{
    if (!_tex || !rgba)
        return;
    const int w = (int)_tex.width, h = (int)_tex.height;
    if (size >= (uint32_t)(w * h * 4))
        [_tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)w * 4];
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
    return Load(n1); // interpolation unsupported in the Metal backend yet
}

MipInfo TextBankMetal::UseMipmap(Texture* absTexture, int /*level*/, int /*top*/)
{
    if (!absTexture)
        return MipInfo(nullptr, 0);
    TextureMetal* texture = static_cast<TextureMetal*>(absTexture);
    texture->LoadHeadersNV();
    texture->EnsureUploaded();
    return MipInfo(texture, 0);
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
