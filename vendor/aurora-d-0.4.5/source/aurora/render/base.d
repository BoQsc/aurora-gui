module aurora.render.base;

import aurora.render.drawlist : DrawList;
import aurora.render.scene : RenderScene;
import aurora.surface : Surface;
import aurora.types : Size;

enum RendererPreference : ubyte
{
    automatic,
    vulkan,
    software
}

/** Backend work counters used by compositor regression tests and diagnostics. */
struct RendererStats
{
    ulong frames;
    ulong frameDeferrals;
    ulong geometryUploads;
    ulong geometryUploadBytes;
    ulong cachedSurfaceBuilds;
    ulong atlasUploads;
    ulong layerDraws;
    ulong fullSceneRedraws;
    ulong partialSceneRedraws;
    ulong dirtyRegionCount;
    ulong dirtyPixels;
}

interface RenderBackend
{
    string name() const;
    bool hardwareAccelerated() const;
    void resize(Size size);
    bool render(DrawList list);
    bool renderScene(RenderScene scene);
    Surface softwareSurface();
    RendererStats stats() const;
    void resetStats();
    void shutdown();
}
