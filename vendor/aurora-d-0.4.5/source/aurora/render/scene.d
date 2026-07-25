module aurora.render.scene;

import aurora.render.drawlist : DrawList;
import aurora.types : Rect, Size;

/** One retained draw-list layer in Aurora's in-process compositor.

    Geometry is local to `deviceBounds.size`; moving the layer changes only
    `deviceBounds.x/y`. `revision` changes only when the layer's content is
    rebuilt, allowing GPU backends to retain vertex and index buffers across
    transform-only frames.
*/
struct RenderLayer
{
    ulong id;
    ulong revision;
    DrawList drawList;
    Rect deviceBounds;
    bool visible = true;
    bool opaque;
}

/** A complete retained compositor frame.

    `base` contains non-layered widgets and is always drawn first. `layers`
    are painter ordered and can move without rebuilding their draw lists.
*/
final class RenderScene
{
    DrawList base;
    ulong baseRevision;
    RenderLayer[] layers;
    Size viewport;
    private void delegate() _lateLatch;

    void reset(DrawList baseList, ulong revision, Size framebufferSize)
    {
        base = baseList;
        baseRevision = revision;
        viewport = framebufferSize;
        layers.length = 0;
    }

    void addLayer(RenderLayer layer)
    {
        if (layer.drawList is null || layer.deviceBounds.empty())
            return;
        layers ~= layer;
    }

    void setLateLatch(void delegate() callback)
    {
        _lateLatch = callback;
    }

    /** Sample interaction state immediately before command recording/composition. */
    void lateLatch()
    {
        if (_lateLatch !is null) _lateLatch();
    }

    size_t retainedLayerCount() const @safe pure nothrow @nogc
    {
        return layers.length;
    }
}

unittest
{
    auto scene = new RenderScene();
    scene.reset(null, 3, Size(1280, 720));
    RenderLayer layer;
    layer.id = 7;
    layer.revision = 2;
    layer.deviceBounds = Rect(10, 20, 100, 80);
    layer.drawList = new DrawList();
    scene.addLayer(layer);
    assert(scene.layers.length == 1);
    assert(scene.layers[0].id == 7);
}
