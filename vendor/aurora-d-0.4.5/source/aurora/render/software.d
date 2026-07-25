module aurora.render.software;

import aurora.color : Color;
import aurora.render.base : RenderBackend, RendererStats;
import aurora.render.drawlist : DrawBatch, DrawBatchKind, DrawList, DrawVertex,
    RgbImageCommand;
import aurora.render.scene : RenderLayer, RenderScene;
import aurora.surface : Surface, blendArgb;
import aurora.types : Rect, Size, maxInt, minInt;
import std.math : ceil, floor;


private final class CachedLayerSurface
{
    Surface surface;
    ulong revision;
    ulong lastSeenScene;

    this(Size size)
    {
        surface = new Surface(maxInt(1, size.width), maxInt(1, size.height));
    }
}

private struct PreviousLayerState
{
    ulong id;
    ulong revision;
    Rect bounds;
    bool visible;
    bool opaque;
}

/** Deterministic CPU triangle renderer and Vulkan reference backend. */
final class SoftwareRenderer : RenderBackend
{
    private Surface _surface;
    private CachedLayerSurface _baseCache;
    private CachedLayerSurface[ulong] _layerCaches;
    private ulong _sceneGeneration;
    private PreviousLayerState[] _previousLayers;
    private ulong _previousBaseRevision;
    private Size _previousViewport;
    private bool _hasPreviousScene;
    private RendererStats _stats;

    this(Size size)
    {
        _surface = new Surface(maxInt(1, size.width), maxInt(1, size.height));
    }

    override string name() const { return "Software"; }
    override bool hardwareAccelerated() const { return false; }
    override Surface softwareSurface() { return _surface; }
    override RendererStats stats() const { return _stats; }
    override void resetStats() { _stats = RendererStats.init; }
    override void shutdown() {}

    override void resize(Size size)
    {
        _surface.resize(maxInt(1, size.width), maxInt(1, size.height));
    }

    override bool render(DrawList list)
    {
        if (list is null) return true;
        ++_stats.frames;
        ++_stats.cachedSurfaceBuilds;
        renderInto(list, _surface);
        return true;
    }

    override bool renderScene(RenderScene scene)
    {
        if (scene is null || scene.base is null) return true;
        scene.lateLatch();
        ++_stats.frames;
        const size = scene.viewport.empty() ? scene.base.viewport : scene.viewport;
        bool resized;
        if (_surface.width() != maxInt(1, size.width) ||
            _surface.height() != maxInt(1, size.height))
        {
            _surface.resize(maxInt(1, size.width), maxInt(1, size.height));
            resized = true;
        }

        if (_baseCache is null || _baseCache.surface.size() != scene.base.viewport)
            _baseCache = new CachedLayerSurface(scene.base.viewport);
        if (_baseCache.revision != scene.baseRevision)
        {
            renderIntoInternal(scene.base, _baseCache.surface, true);
            _baseCache.revision = scene.baseRevision;
            ++_stats.cachedSurfaceBuilds;
        }

        // Rebuild only layer surfaces whose retained draw-list revision changed.
        // This happens before composition so partial dirty-region redraws can
        // reuse every unchanged layer without touching its pixels or geometry.
        ++_sceneGeneration;
        if (_sceneGeneration == 0) ++_sceneGeneration;
        foreach (layer; scene.layers)
        {
            auto found = layer.id in _layerCaches;
            if (found !is null)
                (*found).lastSeenScene = _sceneGeneration;
            if (!layer.visible || layer.drawList is null || layer.deviceBounds.empty())
                continue;
            CachedLayerSurface cache;
            if (found is null)
            {
                cache = new CachedLayerSurface(layer.drawList.viewport);
                cache.lastSeenScene = _sceneGeneration;
                _layerCaches[layer.id] = cache;
            }
            else
                cache = *found;
            if (cache.surface.size() != layer.drawList.viewport)
            {
                cache.surface.resize(maxInt(1, layer.drawList.viewport.width),
                    maxInt(1, layer.drawList.viewport.height));
                cache.revision = 0;
            }
            if (cache.revision != layer.revision)
            {
                // Opaque layers promise a full-surface paint, so clearing a
                // multi-megabyte transparent buffer first is wasted work.
                renderIntoInternal(layer.drawList, cache.surface, !layer.opaque);
                cache.revision = layer.revision;
                ++_stats.cachedSurfaceBuilds;
            }
        }

        const surfaceBounds = Rect(0, 0, _surface.width(), _surface.height());
        bool fullRedraw = resized || !sameLayerIdentity(scene, size) ||
            _previousBaseRevision != scene.baseRevision;
        Rect[] dirtyRegions;
        if (!fullRedraw)
        {
            foreach (index, layer; scene.layers)
            {
                const previous = _previousLayers[index];
                const changed = layer.revision != previous.revision ||
                    layer.deviceBounds != previous.bounds ||
                    layer.visible != previous.visible ||
                    layer.opaque != previous.opaque;
                if (!changed) continue;

                // Transform-only retained layers (notably the timeline
                // playhead) invalidate only their old and new rectangles.
                // Treating a moved layer as a structural scene change would
                // force a complete 1080p window copy for every mouse move or
                // playback tick. Replaying both rectangles also correctly
                // restores content exposed at the old location.
                if (previous.visible)
                    appendDirtyRegion(dirtyRegions,
                        previous.bounds.intersection(surfaceBounds));
                if (layer.visible)
                    appendDirtyRegion(dirtyRegions,
                        layer.deviceBounds.intersection(surfaceBounds));
            }

            long dirtyArea;
            foreach (rect; dirtyRegions)
                dirtyArea += cast(long) rect.width * cast(long) rect.height;
            const surfaceArea = cast(long) _surface.width() * cast(long) _surface.height();
            if (dirtyRegions.length > 10 || dirtyArea * 10 > surfaceArea * 7)
                fullRedraw = true;
        }

        if (fullRedraw)
        {
            ++_stats.fullSceneRedraws;
            ++_stats.dirtyRegionCount;
            _stats.dirtyPixels += cast(ulong) _surface.width() *
                cast(ulong) _surface.height();
            _surface.pixels()[] = _baseCache.surface.pixels()[];
            foreach (layer; scene.layers)
                compositeLayer(layer, surfaceBounds);
        }
        else
        {
            if (dirtyRegions.length > 0) ++_stats.partialSceneRedraws;
            _stats.dirtyRegionCount += dirtyRegions.length;
            foreach (dirty; dirtyRegions)
                _stats.dirtyPixels += cast(ulong) dirty.width * cast(ulong) dirty.height;
            // Playback usually dirties only the Preview rectangle. Restore that
            // rectangle from the cached base, then replay intersecting retained
            // layers in painter order. The rest of the window is never copied.
            foreach (dirty; dirtyRegions)
            {
                copySurfaceRegion(_baseCache.surface, _surface, dirty);
                foreach (layer; scene.layers)
                    compositeLayer(layer, dirty);
            }
        }

        rememberScene(scene, size);

        // Transform-only frames allocate no live-ID scratch array. Caches are
        // marked in place and a removal list is created only when a layer has
        // actually left the scene.
        ulong[] stale;
        foreach (id, cache; _layerCaches)
            if (cache.lastSeenScene != _sceneGeneration) stale ~= id;
        foreach (id; stale) _layerCaches.remove(id);
        return true;
    }

    private bool sameLayerIdentity(RenderScene scene, Size size) const
    {
        if (!_hasPreviousScene || _previousViewport != size ||
            _previousLayers.length != scene.layers.length)
            return false;
        foreach (index, layer; scene.layers)
            if (_previousLayers[index].id != layer.id) return false;
        return true;
    }

    private void rememberScene(RenderScene scene, Size size)
    {
        _previousLayers.length = scene.layers.length;
        foreach (index, layer; scene.layers)
        {
            _previousLayers[index].id = layer.id;
            _previousLayers[index].revision = layer.revision;
            _previousLayers[index].bounds = layer.deviceBounds;
            _previousLayers[index].visible = layer.visible;
            _previousLayers[index].opaque = layer.opaque;
        }
        _previousBaseRevision = scene.baseRevision;
        _previousViewport = size;
        _hasPreviousScene = true;
    }

    private static void appendDirtyRegion(ref Rect[] regions, Rect value)
    {
        if (value.empty()) return;
        size_t index;
        while (index < regions.length)
        {
            const current = regions[index];
            const touches = value.x <= current.right() + 1 &&
                value.right() + 1 >= current.x &&
                value.y <= current.bottom() + 1 &&
                value.bottom() + 1 >= current.y;
            if (!touches)
            {
                ++index;
                continue;
            }
            value = value.unionRect(current);
            regions[index] = regions[$ - 1];
            regions.length = regions.length - 1;
            index = 0;
        }
        regions ~= value;
    }

    private static void copySurfaceRegion(Surface source, Surface destination, Rect region)
    {
        if (source is null || destination is null || region.empty()) return;
        const clipped = region.intersection(Rect(0, 0,
            minInt(source.width(), destination.width()),
            minInt(source.height(), destination.height())));
        if (clipped.empty()) return;
        auto src = source.pixels();
        auto dst = destination.pixels();
        foreach (y; clipped.y .. clipped.bottom())
        {
            const sourceStart = cast(size_t) y * cast(size_t) source.width() +
                cast(size_t) clipped.x;
            const destinationStart = cast(size_t) y * cast(size_t) destination.width() +
                cast(size_t) clipped.x;
            const count = cast(size_t) clipped.width;
            dst[destinationStart .. destinationStart + count] =
                src[sourceStart .. sourceStart + count];
        }
    }

    private void compositeLayer(const RenderLayer layer, Rect dirtyClip)
    {
        if (!layer.visible || layer.drawList is null || layer.deviceBounds.empty() ||
            layer.deviceBounds.intersection(dirtyClip).empty())
            return;
        auto found = layer.id in _layerCaches;
        if (found is null || *found is null) return;
        if (layer.opaque)
            compositeOpaque((*found).surface, _surface,
                layer.deviceBounds.x, layer.deviceBounds.y, dirtyClip);
        else
            compositePremultiplied((*found).surface, _surface,
                layer.deviceBounds.x, layer.deviceBounds.y, dirtyClip);
        ++_stats.layerDraws;
    }

    static void renderSceneInto(RenderScene scene, Surface target)
    {
        if (scene is null || target is null) return;
        auto renderer = new SoftwareRenderer(scene.viewport);
        renderer.renderScene(scene);
        if (target.size() != renderer._surface.size())
            target.resize(renderer._surface.width(), renderer._surface.height());
        target.pixels()[] = renderer._surface.pixels()[];
    }

    static void renderInto(DrawList list, Surface target)
    {
        renderIntoInternal(list, target, true);
    }

    private static void renderIntoInternal(DrawList list, Surface target,
        bool clearTarget)
    {
        if (list is null || target is null) return;
        if (target.width() != maxInt(1, list.viewport.width) ||
            target.height() != maxInt(1, list.viewport.height))
            target.resize(maxInt(1, list.viewport.width), maxInt(1, list.viewport.height));
        if (clearTarget) target.clear(list.clearColor);
        const atlas = list.fonts.atlas;
        const atlasPixels = atlas.pixels();
        const atlasWidth = atlas.width();
        const atlasHeight = atlas.height();
        const surfaceBounds = Rect(0, 0, target.width(), target.height());

        foreach (batch; list.batches)
        {
            const clip = batch.clip.intersection(surfaceBounds);
            if (clip.empty()) continue;
            if (batch.kind == DrawBatchKind.rgbImage)
            {
                if (batch.imageIndex < list.rgbImages.length)
                    rasterRgbImage(target, list.rgbImages[batch.imageIndex], clip);
                continue;
            }

            const end = batch.firstIndex + batch.indexCount;
            uint offset = batch.firstIndex;
            while (offset + 2 < end)
            {
                if (offset + 5 < end && rasterIndexedQuad(target, list, offset,
                    clip, atlasPixels, atlasWidth, atlasHeight))
                {
                    offset += 6;
                    continue;
                }
                const i0 = list.indices[offset];
                const i1 = list.indices[offset + 1];
                const i2 = list.indices[offset + 2];
                if (i0 < list.vertices.length && i1 < list.vertices.length &&
                    i2 < list.vertices.length)
                    rasterTriangle(target, list.vertices[i0], list.vertices[i1],
                        list.vertices[i2], clip, atlasPixels, atlasWidth, atlasHeight);
                offset += 3;
            }
        }
    }

    /**
     * Scaled RGB24 image blit used by video preview frames.
     *
     * The common playback path asks FFmpeg for the exact visible preview size,
     * so the first branch is a division-free row conversion. Scaled paths use
     * incremental 32.32 fixed-point coordinates; bilinear filtering therefore
     * avoids per-pixel floating-point division/floor calls while retaining
     * smooth high-quality downscaling for 1080p, 1440p, and 2160p sources.
     */
    private static void rasterRgbImage(Surface surface, const RgbImageCommand image,
        Rect batchClip)
    {
        if (surface is null || image.destination.empty() || image.width <= 0 ||
            image.height <= 0) return;
        const required = cast(size_t) image.width * cast(size_t) image.height * 3;
        if (image.pixels.length < required) return;
        const clip = image.destination.intersection(image.clip).intersection(batchClip)
            .intersection(Rect(0, 0, surface.width(), surface.height()));
        if (clip.empty()) return;

        auto destination = surface.pixels();
        const destWidth = maxInt(1, image.destination.width);
        const destHeight = maxInt(1, image.destination.height);
        const surfaceWidth = cast(size_t) surface.width();
        const sourceWidth = cast(size_t) image.width;

        // Exact-size playback is the overwhelmingly common case. Convert each
        // RGB24 row directly into Aurora's ARGB surface with no scaling math.
        if (destWidth == image.width && destHeight == image.height)
        {
            const firstSourceX = clip.x - image.destination.x;
            foreach (y; clip.y .. clip.bottom())
            {
                const sourceY = y - image.destination.y;
                auto source = (cast(size_t) sourceY * sourceWidth +
                    cast(size_t) firstSourceX) * 3;
                auto outIndex = cast(size_t) y * surfaceWidth + cast(size_t) clip.x;
                foreach (_; clip.x .. clip.right())
                {
                    destination[outIndex++] = 0xff000000u |
                        (cast(uint) image.pixels[source] << 16) |
                        (cast(uint) image.pixels[source + 1] << 8) |
                        cast(uint) image.pixels[source + 2];
                    source += 3;
                }
            }
            return;
        }

        enum long fixedOne = 1L << 32;
        const long xStep = (cast(long) image.width << 32) / destWidth;
        const long yStep = (cast(long) image.height << 32) / destHeight;

        if (!image.linearFiltering)
        {
            long sourceYFixed = cast(long) (clip.y - image.destination.y) * yStep;
            foreach (y; clip.y .. clip.bottom())
            {
                int sy = cast(int) (sourceYFixed >> 32);
                sy = minInt(image.height - 1, maxInt(0, sy));
                long sourceXFixed = cast(long) (clip.x - image.destination.x) * xStep;
                auto outIndex = cast(size_t) y * surfaceWidth + cast(size_t) clip.x;
                foreach (_; clip.x .. clip.right())
                {
                    int sx = cast(int) (sourceXFixed >> 32);
                    sx = minInt(image.width - 1, maxInt(0, sx));
                    const source = (cast(size_t) sy * sourceWidth +
                        cast(size_t) sx) * 3;
                    destination[outIndex++] = 0xff000000u |
                        (cast(uint) image.pixels[source] << 16) |
                        (cast(uint) image.pixels[source + 1] << 8) |
                        cast(uint) image.pixels[source + 2];
                    sourceXFixed += xStep;
                }
                sourceYFixed += yStep;
            }
            return;
        }

        // Center-sampled bilinear coordinates: (d + 0.5) * scale - 0.5.
        const long halfPixel = fixedOne >> 1;
        long sourceYFixed = cast(long) (clip.y - image.destination.y) * yStep +
            (yStep >> 1) - halfPixel;
        foreach (y; clip.y .. clip.bottom())
        {
            int y0;
            int y1;
            uint fy;
            if (sourceYFixed <= 0)
            {
                y0 = 0;
                y1 = image.height > 1 ? 1 : 0;
                fy = 0;
            }
            else
            {
                y0 = cast(int) (sourceYFixed >> 32);
                if (y0 >= image.height - 1)
                {
                    y0 = image.height - 1;
                    y1 = y0;
                    fy = 0;
                }
                else
                {
                    y1 = y0 + 1;
                    fy = cast(uint) ((sourceYFixed >> 24) & 0xff);
                }
            }
            const uint inverseY = 256u - fy;
            long sourceXFixed = cast(long) (clip.x - image.destination.x) * xStep +
                (xStep >> 1) - halfPixel;
            auto outIndex = cast(size_t) y * surfaceWidth + cast(size_t) clip.x;

            foreach (_; clip.x .. clip.right())
            {
                int x0;
                int x1;
                uint fx;
                if (sourceXFixed <= 0)
                {
                    x0 = 0;
                    x1 = image.width > 1 ? 1 : 0;
                    fx = 0;
                }
                else
                {
                    x0 = cast(int) (sourceXFixed >> 32);
                    if (x0 >= image.width - 1)
                    {
                        x0 = image.width - 1;
                        x1 = x0;
                        fx = 0;
                    }
                    else
                    {
                        x1 = x0 + 1;
                        fx = cast(uint) ((sourceXFixed >> 24) & 0xff);
                    }
                }
                const uint inverseX = 256u - fx;

                const p00 = (cast(size_t) y0 * sourceWidth + cast(size_t) x0) * 3;
                const p10 = (cast(size_t) y0 * sourceWidth + cast(size_t) x1) * 3;
                const p01 = (cast(size_t) y1 * sourceWidth + cast(size_t) x0) * 3;
                const p11 = (cast(size_t) y1 * sourceWidth + cast(size_t) x1) * 3;

                const uint topR = cast(uint) image.pixels[p00] * inverseX +
                    cast(uint) image.pixels[p10] * fx;
                const uint topG = cast(uint) image.pixels[p00 + 1] * inverseX +
                    cast(uint) image.pixels[p10 + 1] * fx;
                const uint topB = cast(uint) image.pixels[p00 + 2] * inverseX +
                    cast(uint) image.pixels[p10 + 2] * fx;
                const uint bottomR = cast(uint) image.pixels[p01] * inverseX +
                    cast(uint) image.pixels[p11] * fx;
                const uint bottomG = cast(uint) image.pixels[p01 + 1] * inverseX +
                    cast(uint) image.pixels[p11 + 1] * fx;
                const uint bottomB = cast(uint) image.pixels[p01 + 2] * inverseX +
                    cast(uint) image.pixels[p11 + 2] * fx;

                const uint red = (topR * inverseY + bottomR * fy + 32_768u) >> 16;
                const uint green = (topG * inverseY + bottomG * fy + 32_768u) >> 16;
                const uint blue = (topB * inverseY + bottomB * fy + 32_768u) >> 16;
                destination[outIndex++] = 0xff000000u | (red << 16) |
                    (green << 8) | blue;
                sourceXFixed += xStep;
            }
            sourceYFixed += yStep;
        }
    }

    /** Fast path for the axis-aligned quads used by backgrounds, controls, and glyphs. */
    private static bool rasterIndexedQuad(Surface surface, DrawList list, uint offset,
        Rect clip, const(ubyte)[] atlas, int atlasWidth, int atlasHeight)
    {
        const i0 = list.indices[offset];
        const i1 = list.indices[offset + 1];
        const i2 = list.indices[offset + 2];
        const i3 = list.indices[offset + 3];
        const i4 = list.indices[offset + 4];
        const i5 = list.indices[offset + 5];
        if (i0 >= list.vertices.length || i1 >= list.vertices.length ||
            i2 >= list.vertices.length || i5 >= list.vertices.length ||
            i3 != i0 || i4 != i2)
            return false;

        const a = list.vertices[i0];
        const b = list.vertices[i1];
        const c = list.vertices[i2];
        const d = list.vertices[i5];
        if (a.y != b.y || b.x != c.x || c.y != d.y || d.x != a.x ||
            b.x <= a.x || c.y <= b.y)
            return false;

        int left = cast(int) ceil(a.x - 0.5f);
        int top = cast(int) ceil(a.y - 0.5f);
        int right = cast(int) ceil(b.x - 0.5f);
        int bottom = cast(int) ceil(d.y - 0.5f);
        left = maxInt(left, clip.x);
        top = maxInt(top, clip.y);
        right = minInt(right, clip.right());
        bottom = minInt(bottom, clip.bottom());
        left = maxInt(left, 0);
        top = maxInt(top, 0);
        right = minInt(right, surface.width());
        bottom = minInt(bottom, surface.height());
        if (right <= left || bottom <= top) return true;

        const sameUv = a.u == b.u && a.u == c.u && a.u == d.u &&
            a.v == b.v && a.v == c.v && a.v == d.v;
        const same = sameColor(a, b) && sameColor(a, c) && sameColor(a, d);
        if (sameUv && same)
        {
            const color = colorOf(a, 1.0f);
            surface.fillRect(Rect(left, top, right - left, bottom - top), color,
                Rect(0, 0, surface.width(), surface.height()));
            return true;
        }

        const vertical = sameUv && sameColor(a, b) && sameColor(c, d);
        if (vertical)
        {
            const height = c.y - a.y;
            foreach (y; top .. bottom)
            {
                const t = clampUnit((y + 0.5f - a.y) / height);
                const color = interpolatedColor(a, c, t, 1.0f);
                fillSpan(surface, y, left, right, color);
            }
            return true;
        }

        const width = b.x - a.x;
        const height = d.y - a.y;
        auto pixels = surface.pixels();
        const surfaceWidth = surface.width();

        // Glyphs and other atlas images use a constant tint. Avoid general
        // four-corner interpolation and keep coverage arithmetic integral.
        if (!sameUv && same)
        {
            const tint = colorOf(a, 1.0f);
            const du = (b.u - a.u) / width;
            const dv = (d.v - a.v) / height;
            foreach (y; top .. bottom)
            {
                const sourceY = cast(int) floor(a.v +
                    (y + 0.5f - a.y) * dv);
                if (sourceY < 0 || sourceY >= atlasHeight) continue;
                auto destination = cast(size_t) y * cast(size_t) surfaceWidth +
                    cast(size_t) left;
                foreach (x; left .. right)
                {
                    const sourceX = cast(int) floor(a.u +
                        (x + 0.5f - a.x) * du);
                    if (sourceX >= 0 && sourceX < atlasWidth)
                    {
                        const coverage = atlas[cast(size_t) sourceY *
                            cast(size_t) atlasWidth + cast(size_t) sourceX];
                        if (coverage != 0)
                        {
                            const alpha = (cast(uint) tint.a * coverage + 127u) / 255u;
                            if (alpha == 255u)
                                pixels[destination] = Color(tint.r, tint.g,
                                    tint.b, 255).argb();
                            else if (alpha != 0u)
                                pixels[destination] = blendArgb(pixels[destination],
                                    Color(tint.r, tint.g, tint.b, cast(ubyte) alpha));
                        }
                    }
                    ++destination;
                }
            }
            return true;
        }

        foreach (y; top .. bottom)
        {
            const ty = clampUnit((y + 0.5f - a.y) / height);
            foreach (x; left .. right)
            {
                const tx = clampUnit((x + 0.5f - a.x) / width);
                const topU = mix(a.u, b.u, tx);
                const bottomU = mix(d.u, c.u, tx);
                const topV = mix(a.v, b.v, tx);
                const bottomV = mix(d.v, c.v, tx);
                const coverage = sameUv ? 1.0f : sampleAtlas(atlas,
                    atlasWidth, atlasHeight, mix(topU, bottomU, ty),
                    mix(topV, bottomV, ty));
                if (coverage <= 0.0f) continue;

                const topR = mix(a.r, b.r, tx);
                const bottomR = mix(d.r, c.r, tx);
                const topG = mix(a.g, b.g, tx);
                const bottomG = mix(d.g, c.g, tx);
                const topB = mix(a.b, b.b, tx);
                const bottomB = mix(d.b, c.b, tx);
                const topA = mix(a.a, b.a, tx);
                const bottomA = mix(d.a, c.a, tx);
                const color = Color(
                    cast(ubyte) clampByte(mix(topR, bottomR, ty) * 255.0f),
                    cast(ubyte) clampByte(mix(topG, bottomG, ty) * 255.0f),
                    cast(ubyte) clampByte(mix(topB, bottomB, ty) * 255.0f),
                    cast(ubyte) clampByte(mix(topA, bottomA, ty) * coverage * 255.0f));
                if (color.a == 0) continue;
                const index = cast(size_t) y * cast(size_t) surfaceWidth +
                    cast(size_t) x;
                pixels[index] = blendArgb(pixels[index], color);
            }
        }
        return true;
    }

    private static void compositeOpaque(Surface source, Surface destination,
        int offsetX, int offsetY, Rect dirtyClip)
    {
        if (source is null || destination is null) return;
        const destinationBounds = Rect(0, 0, destination.width(), destination.height());
        const sourceBounds = Rect(offsetX, offsetY, source.width(), source.height());
        const clipped = sourceBounds.intersection(destinationBounds).intersection(dirtyClip);
        if (clipped.empty()) return;
        auto src = source.pixels();
        auto dst = destination.pixels();
        foreach (y; clipped.y .. clipped.bottom())
        {
            const sourceStart = cast(size_t) (y - offsetY) *
                cast(size_t) source.width() + cast(size_t) (clipped.x - offsetX);
            const destinationStart = cast(size_t) y *
                cast(size_t) destination.width() + cast(size_t) clipped.x;
            const count = cast(size_t) clipped.width;
            dst[destinationStart .. destinationStart + count] =
                src[sourceStart .. sourceStart + count];
        }
    }

    private static void compositePremultiplied(Surface source, Surface destination,
        int offsetX, int offsetY, Rect dirtyClip)
    {
        if (source is null || destination is null) return;
        const destinationBounds = Rect(0, 0, destination.width(), destination.height());
        const sourceBounds = Rect(offsetX, offsetY, source.width(), source.height());
        const clipped = sourceBounds.intersection(destinationBounds).intersection(dirtyClip);
        if (clipped.empty()) return;
        const left = clipped.x;
        const top = clipped.y;
        const right = clipped.right();
        const bottom = clipped.bottom();
        auto src = source.pixels();
        auto dst = destination.pixels();
        foreach (y; top .. bottom)
        {
            auto sourceIndex = cast(size_t) (y - offsetY) * cast(size_t) source.width() +
                cast(size_t) (left - offsetX);
            auto destinationIndex = cast(size_t) y * cast(size_t) destination.width() +
                cast(size_t) left;
            foreach (_; left .. right)
            {
                const packed = src[sourceIndex++];
                const alpha = (packed >> 24) & 0xffu;
                if (alpha == 255u)
                    dst[destinationIndex] = packed;
                else if (alpha != 0u)
                {
                    const inverse = 255u - alpha;
                    const dr = (dst[destinationIndex] >> 16) & 0xffu;
                    const dg = (dst[destinationIndex] >> 8) & 0xffu;
                    const db = dst[destinationIndex] & 0xffu;
                    const da = (dst[destinationIndex] >> 24) & 0xffu;
                    const sr = (packed >> 16) & 0xffu;
                    const sg = (packed >> 8) & 0xffu;
                    const sb = packed & 0xffu;
                    const rr = sr + (dr * inverse + 127u) / 255u;
                    const rg = sg + (dg * inverse + 127u) / 255u;
                    const rb = sb + (db * inverse + 127u) / 255u;
                    const ra = alpha + (da * inverse + 127u) / 255u;
                    dst[destinationIndex] = (ra << 24) |
                        ((rr > 255u ? 255u : rr) << 16) |
                        ((rg > 255u ? 255u : rg) << 8) |
                        (rb > 255u ? 255u : rb);
                }
                ++destinationIndex;
            }
        }
    }

    private static void fillSpan(Surface surface, int y, int left, int right, Color color)
    {
        if (color.a == 0 || right <= left) return;
        auto pixels = surface.pixels();
        auto index = cast(size_t) y * cast(size_t) surface.width() + cast(size_t) left;
        const end = index + cast(size_t) (right - left);
        if (color.a == 255)
        {
            pixels[index .. end] = color.argb();
            return;
        }
        for (; index < end; ++index)
            pixels[index] = blendArgb(pixels[index], color);
    }

    private static bool sameColor(DrawVertex a, DrawVertex b)
        @safe pure nothrow @nogc
    {
        return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
    }

    private static Color colorOf(DrawVertex value, float coverage)
        @safe pure nothrow @nogc
    {
        return Color(
            cast(ubyte) clampByte(value.r * 255.0f),
            cast(ubyte) clampByte(value.g * 255.0f),
            cast(ubyte) clampByte(value.b * 255.0f),
            cast(ubyte) clampByte(value.a * coverage * 255.0f));
    }

    private static Color interpolatedColor(DrawVertex from, DrawVertex to,
        float amount, float coverage) @safe pure nothrow @nogc
    {
        return Color(
            cast(ubyte) clampByte(mix(from.r, to.r, amount) * 255.0f),
            cast(ubyte) clampByte(mix(from.g, to.g, amount) * 255.0f),
            cast(ubyte) clampByte(mix(from.b, to.b, amount) * 255.0f),
            cast(ubyte) clampByte(mix(from.a, to.a, amount) * coverage * 255.0f));
    }

    private static float mix(float from, float to, float amount)
        @safe pure nothrow @nogc
    {
        return from + (to - from) * amount;
    }

    private static float clampUnit(float value) @safe pure nothrow @nogc
    {
        if (value <= 0.0f) return 0.0f;
        if (value >= 1.0f) return 1.0f;
        return value;
    }

    private static void rasterTriangle(Surface surface, DrawVertex originalA,
        DrawVertex originalB, DrawVertex originalC, Rect clip,
        const(ubyte)[] atlas, int atlasWidth, int atlasHeight)
    {
        auto a = originalA;
        auto b = originalB;
        auto c = originalC;
        double area = edge(a, b, c.x, c.y);
        if (area == 0.0) return;
        if (area < 0.0)
        {
            auto temporary = b;
            b = c;
            c = temporary;
            area = -area;
        }

        int left = cast(int) floor(min3(a.x, b.x, c.x));
        int top = cast(int) floor(min3(a.y, b.y, c.y));
        int right = cast(int) floor(max3(a.x, b.x, c.x)) + 1;
        int bottom = cast(int) floor(max3(a.y, b.y, c.y)) + 1;
        left = maxInt(left, clip.x);
        top = maxInt(top, clip.y);
        right = minInt(right, clip.right());
        bottom = minInt(bottom, clip.bottom());
        if (right <= left || bottom <= top) return;

        const edge0TopLeft = isTopLeft(b, c);
        const edge1TopLeft = isTopLeft(c, a);
        const edge2TopLeft = isTopLeft(a, b);
        auto pixels = surface.pixels();
        const width = surface.width();

        const solidUv = a.u == b.u && a.u == c.u &&
            a.v == b.v && a.v == c.v;
        if (solidUv && sameColor(a, b) && sameColor(a, c))
        {
            // Circles, rounded corners, icons, and non-axis-aligned lines are
            // solid-color triangles. Increment edge equations across each row
            // and avoid atlas sampling plus barycentric color interpolation.
            const source = colorOf(a, 1.0f);
            const packed = source.argb();
            const stepX0 = -(c.y - b.y);
            const stepX1 = -(a.y - c.y);
            const stepX2 = -(b.y - a.y);
            foreach (y; top .. bottom)
            {
                const py = y + 0.5;
                double w0 = edge(b, c, left + 0.5, py);
                double w1 = edge(c, a, left + 0.5, py);
                double w2 = edge(a, b, left + 0.5, py);
                auto index = cast(size_t) y * cast(size_t) width +
                    cast(size_t) left;
                foreach (_; left .. right)
                {
                    if (accepted(w0, edge0TopLeft) &&
                        accepted(w1, edge1TopLeft) &&
                        accepted(w2, edge2TopLeft))
                    {
                        if (source.a == 255)
                            pixels[index] = packed;
                        else if (source.a != 0)
                            pixels[index] = blendArgb(pixels[index], source);
                    }
                    w0 += stepX0;
                    w1 += stepX1;
                    w2 += stepX2;
                    ++index;
                }
            }
            return;
        }

        const inverseArea = 1.0 / area;
        foreach (y; top .. bottom)
        {
            const py = y + 0.5;
            foreach (x; left .. right)
            {
                const px = x + 0.5;
                const w0 = edge(b, c, px, py);
                const w1 = edge(c, a, px, py);
                const w2 = edge(a, b, px, py);
                if (!accepted(w0, edge0TopLeft) || !accepted(w1, edge1TopLeft) ||
                    !accepted(w2, edge2TopLeft)) continue;
                const f0 = w0 * inverseArea;
                const f1 = w1 * inverseArea;
                const f2 = w2 * inverseArea;
                const u = a.u * f0 + b.u * f1 + c.u * f2;
                const v = a.v * f0 + b.v * f1 + c.v * f2;
                const coverage = sampleAtlas(atlas, atlasWidth, atlasHeight, u, v);
                if (coverage <= 0.0f) continue;
                const red = clampByte((a.r * f0 + b.r * f1 + c.r * f2) * 255.0);
                const green = clampByte((a.g * f0 + b.g * f1 + c.g * f2) * 255.0);
                const blue = clampByte((a.b * f0 + b.b * f1 + c.b * f2) * 255.0);
                const alpha = clampByte((a.a * f0 + b.a * f1 + c.a * f2) * coverage * 255.0);
                if (alpha == 0) continue;
                const index = cast(size_t) y * cast(size_t) width + cast(size_t) x;
                const source = Color(cast(ubyte) red, cast(ubyte) green,
                    cast(ubyte) blue, cast(ubyte) alpha);
                pixels[index] = blendArgb(pixels[index], source);
            }
        }
    }

    private static double edge(DrawVertex a, DrawVertex b, double x, double y)
        @safe pure nothrow @nogc
    {
        return (cast(double) b.x - a.x) * (y - a.y) -
            (cast(double) b.y - a.y) * (x - a.x);
    }

    private static bool isTopLeft(DrawVertex a, DrawVertex b) @safe pure nothrow @nogc
    {
        const dy = b.y - a.y;
        const dx = b.x - a.x;
        return dy < 0.0f || (dy == 0.0f && dx > 0.0f);
    }

    private static bool accepted(double value, bool topLeft) @safe pure nothrow @nogc
    {
        return value > 0.0 || (value == 0.0 && topLeft);
    }

    private static float sampleAtlas(const(ubyte)[] pixels, int width, int height,
        float u, float v) @safe pure nothrow @nogc
    {
        if (pixels.length == 0 || width <= 0 || height <= 0) return 1.0f;
        // DrawList emits physical-sized, pixel-snapped glyph quads. Preserve
        // the atlas rasterizer's coverage exactly instead of filtering it a
        // second time in the reference renderer.
        const x = cast(int) floor(u);
        const y = cast(int) floor(v);
        if (x < 0 || y < 0 || x >= width || y >= height) return 0.0f;
        return pixels[cast(size_t) y * cast(size_t) width + cast(size_t) x] / 255.0f;
    }

    private static int clampByte(double value) @safe pure nothrow @nogc
    {
        if (value <= 0.0) return 0;
        if (value >= 255.0) return 255;
        return cast(int) (value + 0.5);
    }

    private static float min3(float a, float b, float c) @safe pure nothrow @nogc
    {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }

    private static float max3(float a, float b, float c) @safe pure nothrow @nogc
    {
        return a > b ? (a > c ? a : c) : (b > c ? b : c);
    }
}

unittest
{
    import aurora.color : Color;
    import aurora.render.drawlist : DrawList;
    auto list = new DrawList();
    list.reset(Size(32, 32), Color.rgb(0, 0, 0));
    list.addSolidRect(Rect(4, 4, 16, 12), Color.rgb(255, 0, 0), Rect(0, 0, 32, 32));
    auto surface = new Surface(32, 32);
    SoftwareRenderer.renderInto(list, surface);
    assert(surface.pixel(8, 8) == 0xffff0000);
}

unittest
{
    // Rounded rectangles are decomposed into non-overlapping fast rectangles
    // and local corner fans. Translucent pixels at their shared boundaries
    // must be blended exactly once.
    const clear = Color.rgb(12, 18, 24);
    const translucent = Color.rgba(220, 80, 40, 128);
    auto list = new DrawList();
    list.reset(Size(40, 30), clear);
    list.addRoundedRect(Rect(5, 5, 28, 18), 6, translucent,
        Rect(0, 0, 40, 30));
    auto surface = new Surface(40, 30);
    SoftwareRenderer.renderInto(list, surface);

    const expected = blendArgb(clear.argb(), translucent);
    assert(surface.pixel(19, 5) == expected);  // top-center rectangle
    assert(surface.pixel(5, 14) == expected);  // left-center rectangle
    assert(surface.pixel(19, 14) == expected); // interior rectangle
    assert(surface.pixel(5, 5) == clear.argb());
    assert(surface.pixel(8, 8) == expected);    // local corner fan
}
