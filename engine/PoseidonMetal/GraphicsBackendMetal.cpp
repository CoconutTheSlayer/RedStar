#include <Poseidon/Graphics/GraphicsEngineFactory.hpp>
#include <PoseidonMetal/EngineFactoryMetal.hpp>

using Poseidon::Engine;
using Poseidon::GraphicsBackendDescriptor;
using Poseidon::GraphicsEngineFactory;
using Poseidon::GraphicsEngineParams;

// Implemented in MetalAvailable.mm (needs Metal headers).
namespace Poseidon
{
bool MetalBackendAvailable();
}

namespace
{
Engine* CreateMetalBackend(const GraphicsEngineParams& params)
{
    return Poseidon::CreateEngineMetal(params.width, params.height, params.useWindow, params.bitsPerPixel);
}
} // namespace

namespace Poseidon
{
void RegisterMetalGraphicsBackend()
{
    GraphicsEngineFactory::Register(GraphicsBackendDescriptor{
        "metal",
        "Metal (SDL3/CAMetalLayer)",
        // Priority kept BELOW gl33 (100) during development so `auto`/default
        // stays on the complete GL backend; opt in explicitly with --render metal.
        // Bump above gl33 once the Metal backend reaches feature parity (M7).
        10,
        &CreateMetalBackend,
        &MetalBackendAvailable,
    });
}
} // namespace Poseidon
