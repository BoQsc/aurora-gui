module auroramesh.gpubackend;

/**
 * Chooses between the Vulkan viewport renderer and the software rasterizer.
 *
 * The editor and the command line both go through here, so one switch decides
 * the backend for interactive frames, captures, and animation sheets.
 */
import auroramesh.camera : Camera;
public import auroramesh.gpu : gpuAvailable, gpuDeviceIndex, gpuDeviceName,
    gpuUnavailableReason, gpuTrace;
import auroramesh.gpu : GpuMeshRenderer, GpuStats;
import auroramesh.mesh : Mesh;
import auroramesh.renderer : GpuTriangle, RgbFrame, RenderOptions, renderMesh;
import std.stdio : stderr;

private GpuMeshRenderer renderer;
private bool attempted;
private bool chosen = true; // GPU preferred unless the caller opts out
private string lastError;
private GpuStats lastStats;

/// Restrict the self test to one attempt, for driver debugging.
string gpuSelfTestOnly;

/// Turn GPU rendering on or off before the first frame is drawn.
void useGpu(bool enabled)
{
    chosen = enabled;
}

bool gpuPreferred()
{
    return chosen;
}

/// True when the viewport really renders on the GPU right now.
bool renderingOnGpu()
{
    return chosen && renderer !is null;
}

string viewportBackend()
{
    if (renderer !is null)
        return "vulkan (" ~ gpuDeviceName() ~ ")";
    return "software";
}

string viewportFallbackReason()
{
    return lastError;
}

GpuStats viewportStats()
{
    return lastStats;
}

private GpuMeshRenderer backend()
{
    if (!chosen || attempted)
        return renderer;
    attempted = true;
    if (!gpuAvailable())
    {
        lastError = gpuUnavailableReason();
        return null;
    }
    try
    {
        renderer = new GpuMeshRenderer();
    }
    catch (Exception error)
    {
        lastError = error.msg;
        renderer = null;
    }
    if (renderer is null && lastError.length > 0)
        stderr.writeln("GPU viewport unavailable: " ~ lastError);
    lastStats = GpuStats.init;
    return renderer;
}

/// Render one viewport frame with the best available backend.
RgbFrame renderFrame(const Mesh mesh, const Camera camera, int width,
    int height, RenderOptions options = RenderOptions())
{
    if (auto device = backend())
    {
        try
        {
            // One projection pass: the software renderer draws the background,
            // grid and overlays and hands the projected mesh triangles to the
            // GPU rasterizer, so both paths shade identical geometry.
            GpuTriangle[] triangles;
            auto frame = renderMesh(mesh, camera, width, height, options,
                &triangles);
            // A device can accept a frame and still cover nothing. An empty
            // viewport is never acceptable, so treat that as a device fault.
            if (!device.rasterizeTriangles(triangles, width, height, frame))
            {
                lastError = "the Vulkan device returned an empty frame";
                stderr.writeln("GPU frame was empty, falling back to software");
                renderer.dispose();
            }
            else
            {
                lastStats = device.stats();
                return frame;
            }
        }
        catch (Exception error)
        {
            // A device lost or driver bug must not lose the viewport.
            lastError = error.msg;
            stderr.writeln("GPU frame failed, falling back to software: " ~
                error.msg);
        }
        renderer = null;
    }
    return renderMesh(mesh, camera, width, height, options);
}

/// True when every pixel equals the first one, so nothing was rasterized.
private bool flatFrame(const RgbFrame frame)
{
    if (frame.pixels.length < 4)
        return true;
    foreach (index, value; frame.pixels)
        if (value != frame.pixels[index % 3])
            return false;
    return true;
}

unittest
{
    // The guard that keeps an empty device frame off the screen: a uniform
    // frame is rejected, a single differing channel is enough to keep it.
    RgbFrame frame;
    frame.pixels = [10, 20, 30, 10, 20, 30, 10, 20, 30, 10, 20, 30];
    assert(flatFrame(frame), "a uniform frame must count as empty");
    frame.pixels[7] = 31;
    assert(!flatFrame(frame), "one drawn pixel must survive the guard");
    RgbFrame tiny;
    tiny.pixels = [1, 2, 3];
    assert(flatFrame(tiny), "a frame too small to hold a pixel is empty");
}

/// Release device resources, for example before the process exits.
void shutdownGpu()
{
    if (renderer !is null)
        renderer.dispose();
    renderer = null;
}

/// Build a pipeline from Aurora's own shaders to diagnose the device.
/// Draw a triangle with Aurora's own shader pair and a white 1x1 texture.
bool gpuSmokePair(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeAuroraPair(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Rasterize two known triangles through the compute kernel.
bool gpuSmokeRaster(out string report)
{
    import std.stdio : stderr;
    stderr.writeln("[raster] request");
    try
    {
        auto device = new GpuMeshRenderer(true);
        stderr.writeln("[raster] device");
        scope (exit) device.dispose();
        return device.smokeComputeRaster(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Dispatch a compute shader that paints pixels into a storage image.
bool gpuSmokeImage(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeComputeImage(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Draw a triangle positioned from gl_VertexIndex, with no vertex buffer at all.
bool gpuSmokeIndex(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeIndexTriangle(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Draw a triangle with Aurora's own vertex shader in this plumbing.
bool gpuSmokeCompute(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeCompute(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Draw a triangle with Aurora's own vertex shader in this plumbing.
bool gpuSmokeAurora(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeAuroraVertex(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Draw a single constant point, to separate rasterization from vertex fetch.
bool gpuSmokePoint(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokePoint(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Draw a clip-space triangle to verify that rasterization works at all.
bool gpuSmokeTest(out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.smokeTest(report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

/// Create a pipeline from two SPIR-V files, for diagnosing a driver.
bool gpuProbeShaders(string vertexPath, string fragmentPath, out string report)
{
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        return device.probeFiles(vertexPath, fragmentPath, report);
    }
    catch (Exception error)
    {
        report = error.msg;
        return false;
    }
}

bool gpuSelfTest(out string report)
{
    // Build the device without the generated-shader pipelines: those are
    // exactly what the self test is meant to rule out.
    try
    {
        auto device = new GpuMeshRenderer(true);
        scope (exit) device.dispose();
        string detail;
        const ok = device.selfTest(detail, gpuSelfTestOnly);
        report = device.deviceName ~ ": " ~ detail;
        return ok;
    }
    catch (Exception error)
    {
        report = "device bring-up failed: " ~ error.msg;
        return false;
    }
}
