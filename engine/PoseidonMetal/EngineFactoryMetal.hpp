#pragma once

// Metal backend constructor entry-point.  Mirrors EngineFactory.hpp's
// CreateEngineGL33 so GraphicsBackendMetal.cpp (pure C++) can create the engine
// without pulling in any Objective-C / Metal headers.

namespace Poseidon
{
class Engine;

Engine* CreateEngineMetal(int w, int h, bool windowed, int bpp);

} // namespace Poseidon
