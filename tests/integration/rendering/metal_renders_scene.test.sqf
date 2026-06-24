// Render smoke regression: the 3D intro scene behind the main menu must render
// real content — catches a blank/black frame, a broken shader, or a crashed
// backend.  Backend-agnostic, but the point is to run it with `--render metal`
// (it exercises EngineMetal::SamplePixel + the whole Metal draw path) so the
// Metal backend can't silently regress versus the GL33 reference.
//
//   PoseidonGame --test-mission tests/integration/rendering/metal_renders_scene.test.sqf \
//                --test-type autotest --render metal -C <data-dir>

triSetLanguage "English"
triSimFrames 60

// The scene actually rendered: the centre pixel is not near-black.
triAssert [(triGetPixelMaxChannel [0.5, 0.5]) > 16]

// And it is a real scene, not a flat fill / broken-shader single colour: two
// far-apart pixels differ noticeably.
triAssert [(triGetPixelMaxDiff [0.15, 0.2, 0.85, 0.85]) > 16]

triScreenshot "metal_renders_scene"
triEndTest
