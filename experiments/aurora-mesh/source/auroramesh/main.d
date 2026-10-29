module auroramesh.main;

version (Windows)
    import auroramesh.crt.msvcrt_shim;

import auroramesh.camera : Camera;
import auroramesh.editor : MeshEditor;
import auroramesh.mesh : Mesh, humanBaseMesh, meshEdgeStats, meshMaximum,
    meshMinimum, parseObj, toObj, validMesh, watertight;
import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.human_v3 : humanBaseMeshV3;
import auroramesh.glb : fromGlb, toGlb;
import auroramesh.gpubackend : gpuAvailable, gpuDeviceName, gpuUnavailableReason,
    gpuDeviceIndex, gpuProbeShaders, gpuSelfTest, gpuSelfTestOnly, gpuSmokeAurora,
    gpuSmokeCompute, gpuSmokePair, gpuSmokePoint, gpuSmokeTest, gpuTrace,
    gpuSmokeImage, gpuSmokeIndex, gpuSmokeRaster, renderFrame, shutdownGpu,
    useGpu, viewportBackend,
    viewportFallbackReason, viewportStats;
import auroramesh.gltf_scene : GltfScene, bakeGltfFrame, loadGltfScene;
import auroramesh.renderer : RenderOptions, renderMesh, softwareStats, writePpm;
import auroramesh.rig_fixture : buildRigFixture, rigFixtureGlb;
import aurora : GuiWindow, RendererPreference, Theme, WindowOptions;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, mkdirRecurse, read, readText, write;
import std.format : format;
import std.math : isFinite;
import std.path : dirName;
import std.stdio : stderr, writeln;

private void usage()
{
    writeln("aurora-mesh — simple 3D mesh editor and human base mesh");
    writeln("  aurora-mesh                         open the editor");
    writeln("  aurora-mesh --screenshot <file.ppm>  render the editor window and exit");
    writeln("  aurora-mesh --render <file.ppm>      headless 3D render");
    writeln("  aurora-mesh --gpu-info               report the viewport GPU backend");
    writeln("  aurora-mesh --gpu-selftest           build a pipeline from Aurora's own shaders");
    writeln("  aurora-mesh --gpu-smoke              draw a clip-space triangle and report the pixel");
    writeln("  aurora-mesh --gpu-smoke-point        draw a constant point, no vertex buffer");
    writeln("  aurora-mesh --gpu-smoke-aurora       draw with Aurora's vertex shader in this plumbing");
    writeln("  aurora-mesh --gpu-smoke-pair         draw with Aurora's shader pair and a white texture");
    writeln("  aurora-mesh --gpu-smoke-compute      dispatch a compute shader that stores a value");
    writeln("  aurora-mesh --gpu-smoke-index        draw from gl_VertexIndex with no vertex buffer");
    writeln("  aurora-mesh --gpu-smoke-image        paint pixels from a compute dispatch");
    writeln("  --gpu-device <index>                 choose the Vulkan physical device");
    writeln("  aurora-mesh --gpu-trace             trace device bring-up and frame setup");
    writeln("  aurora-mesh --bench [frames]         time software and Vulkan viewport frames");
    writeln("  --gpu / --no-gpu                     force the viewport backend");
    writeln("  aurora-mesh --check                  validate and print mesh statistics");
    writeln("  aurora-mesh --export-obj <file.obj>  write the human base mesh");
    writeln("  aurora-mesh --export-glb <file.glb>  write a glTF 2.0 binary mesh");
    writeln("  aurora-mesh --export-rig <file.glb>  write the skinned test rig fixture");
    writeln("  aurora-mesh --export-static-glb <file.glb>  bake textures/UVs into a static GLB");
    writeln("  aurora-mesh --obj <file.obj>         load a mesh into the editor");
    writeln("  aurora-mesh --glb <file.glb>         load a GLB mesh into the editor");
    writeln("  --glb-anim <name|index>              select a GLB animation clip");
    writeln("  --glb-time <seconds>                 set the GLB animation time");
    writeln("  --glb-morph                          enable animated morph weights");
    writeln("  --live <file.json>                   watch a live authoring command file");
    writeln("  --v3                                 use the natural low-poly human (default)");
    writeln("  --v2                                 use the organic generated human");
    writeln("  --v1                                 use the original primitive human");
    writeln("  options: --width <pixels> --height <pixels>");
}

int main(string[] args)
{
    string renderPath;
    string exportPath;
    string loadPath;
    string glbLoadPath;
    string glbExportPath;
    string staticGlbExportPath;
    string rigExportPath;
    GltfScene gltfScene;
    bool hasGltfScene;
    string glbAnimation;
    double glbTime;
    int selectedAnimation;
    bool noMorph;
    string screenshotPath;
    string livePath = "build/live.json";
    string objPath = "mesh.obj";
    bool check;
    int humanVersion = 3;
    int width = 1400;
    int height = 860;
    bool gpuDisabled;
    bool gpuInfo;
    bool gpuSelfTestRequested;
    bool smokeRequested;
    bool pointSmokeRequested;
    bool auroraSmokeRequested;
    bool pairSmokeRequested;
    bool computeSmokeRequested;
    bool indexSmokeRequested;
    bool imageSmokeRequested;
    bool rasterSmokeRequested;
    int deviceIndexRequested = -1;
    string[] probeArguments;
    int benchFrames;
    bool benchRequested;

    for (size_t index = 1; index < args.length; index++)
    {
        switch (args[index])
        {
            case "--help":
            case "-h":
                usage();
                return 0;
            case "--check":
                check = true;
                break;
            case "--gpu":
                useGpu(true);
                gpuDisabled = false;
                break;
            case "--no-gpu":
                useGpu(false);
                gpuDisabled = true;
                break;
            case "--gpu-info":
                gpuInfo = true;
                break;
            case "--gpu-selftest":
                gpuSelfTestRequested = true;
                break;
            case "--gpu-attempt":
                if (++index >= args.length)
                {
                    stderr.writeln("--gpu-attempt needs a self-test name");
                    return 2;
                }
                gpuSelfTestOnly = args[index];
                gpuSelfTestRequested = true;
                break;
            case "--gpu-smoke":
                smokeRequested = true;
                break;
            case "--gpu-smoke-point":
                pointSmokeRequested = true;
                break;
            case "--gpu-smoke-aurora":
                auroraSmokeRequested = true;
                break;
            case "--gpu-smoke-pair":
                pairSmokeRequested = true;
                break;
            case "--gpu-smoke-compute":
                computeSmokeRequested = true;
                break;
            case "--gpu-smoke-index":
                indexSmokeRequested = true;
                break;
            case "--gpu-smoke-image":
                imageSmokeRequested = true;
                break;
            case "--gpu-smoke-raster":
                rasterSmokeRequested = true;
                break;
            case "--gpu-device":
                if (index + 1 < args.length)
                    deviceIndexRequested = to!int(args[++index]);
                break;
            case "--gpu-probe":
                if (index + 2 >= args.length)
                {
                    stderr.writeln("--gpu-probe needs a vertex and fragment file");
                    return 2;
                }
                probeArguments = [args[++index], args[++index]];
                break;
            case "--gpu-trace":
                gpuTrace(true);
                break;
            case "--bench":
                benchRequested = true;
                if (index + 1 < args.length && args[index + 1].length > 0 &&
                    args[index + 1][0] != '-')
                    benchFrames = to!int(args[++index]);
                if (benchFrames <= 0)
                    benchFrames = 20;
                break;
            case "--render":
                if (++index >= args.length)
                {
                    stderr.writeln("--render needs a path");
                    return 2;
                }
                renderPath = args[index];
                break;
            case "--export-obj":
                if (++index >= args.length)
                {
                    stderr.writeln("--export-obj needs a path");
                    return 2;
                }
                exportPath = args[index];
                break;
            case "--export-glb":
                if (++index >= args.length)
                {
                    stderr.writeln("--export-glb needs a path");
                    return 2;
                }
                glbExportPath = args[index];
                break;
            case "--export-static-glb":
                if (++index >= args.length)
                {
                    stderr.writeln("--export-static-glb needs a path");
                    return 2;
                }
                staticGlbExportPath = args[index];
                break;
            case "--export-rig":
                if (++index >= args.length)
                {
                    stderr.writeln("--export-rig needs a path");
                    return 2;
                }
                rigExportPath = args[index];
                break;
            case "--obj":
                if (++index >= args.length)
                {
                    stderr.writeln("--obj needs a path");
                    return 2;
                }
                loadPath = args[index];
                objPath = loadPath;
                break;
            case "--glb":
                if (++index >= args.length)
                {
                    stderr.writeln("--glb needs a path");
                    return 2;
                }
                glbLoadPath = args[index];
                break;
            case "--glb-anim":
                if (++index >= args.length)
                {
                    stderr.writeln("--glb-anim needs a name or index");
                    return 2;
                }
                glbAnimation = args[index];
                break;
            case "--glb-time":
                if (++index >= args.length)
                {
                    stderr.writeln("--glb-time needs seconds");
                    return 2;
                }
                glbTime = to!double(args[index]);
                break;
            case "--glb-no-morph":
                noMorph = true;
                break;
            case "--glb-morph":
                noMorph = false;
                break;
            case "--live":
                if (++index >= args.length)
                {
                    stderr.writeln("--live needs a JSON path");
                    return 2;
                }
                livePath = args[index];
                break;
            case "--screenshot":
                if (++index >= args.length)
                {
                    stderr.writeln("--screenshot needs a path");
                    return 2;
                }
                screenshotPath = args[index];
                break;
            case "--width":
                if (++index >= args.length)
                {
                    stderr.writeln("--width needs a number");
                    return 2;
                }
                width = to!int(args[index]);
                break;
            case "--height":
                if (++index >= args.length)
                {
                    stderr.writeln("--height needs a number");
                    return 2;
                }
                height = to!int(args[index]);
                break;
            case "--v1":
                humanVersion = 1;
                break;
            case "--v2":
                humanVersion = 2;
                break;
            case "--v3":
                humanVersion = 3;
                break;
            default:
                stderr.writeln("unknown option: " ~ args[index]);
                usage();
                return 2;
        }
    }

    if (deviceIndexRequested >= 0)
        gpuDeviceIndex = deviceIndexRequested;

    if (rigExportPath.length > 0)
    {
        ensureParent(rigExportPath);
        try
            write(rigExportPath, rigFixtureGlb(buildRigFixture()));
        catch (Exception error)
        {
            stderr.writeln("Rig export failed: " ~ error.msg);
            return 1;
        }
        writeln("wrote " ~ rigExportPath);
        return 0;
    }

    Mesh mesh = humanVersion == 1 ? humanBaseMesh() :
        humanVersion == 2 ? humanBaseMeshV2() : humanBaseMeshV3();
    if (glbLoadPath.length > 0)
    {
        if (!exists(glbLoadPath))
        {
            stderr.writeln("mesh not found: " ~ glbLoadPath);
            return 1;
        }
        try
        {
            gltfScene = loadGltfScene(cast(ubyte[]) read(glbLoadPath));
            hasGltfScene = true;
            int animationIndex;
            if (glbAnimation == "none")
                animationIndex = -1;
            else if (glbAnimation.length > 0)
            {
                bool found;
                foreach (index, animation; gltfScene.animations)
                    if (animation.name == glbAnimation)
                    {
                        animationIndex = cast(int) index;
                        found = true;
                        break;
                    }
                if (!found)
                    animationIndex = to!int(glbAnimation);
            }
            selectedAnimation = animationIndex;
            mesh = bakeGltfFrame(gltfScene, animationIndex, glbTime, !noMorph);
        }
        catch (Exception error)
        {
            stderr.writeln("GLB load failed: " ~ error.msg);
            return 1;
        }
        if (mesh.vertices.length == 0)
        {
            stderr.writeln("mesh has no vertices: " ~ glbLoadPath);
            return 1;
        }
    }
    else if (loadPath.length > 0)
    {
        if (!exists(loadPath))
        {
            stderr.writeln("mesh not found: " ~ loadPath);
            return 1;
        }
        mesh = parseObj(readText(loadPath));
        if (mesh.vertices.length == 0)
        {
            stderr.writeln("mesh has no vertices: " ~ loadPath);
            return 1;
        }
    }

    if (check)
    {
        if (loadPath.length == 0 && glbLoadPath.length == 0 &&
            (mesh.vertices.length < 100 ||
            mesh.faces.length < 100))
        {
            stderr.writeln("human mesh is unexpectedly small");
            return 1;
        }
        if (!validMesh(mesh))
        {
            stderr.writeln(format(
                "mesh validation failed: vertices=%d faces=%d normals=%d",
                mesh.vertices.length, mesh.faces.length, mesh.normals.length));
            if (mesh.vertices.length > 0)
            {
                const first = mesh.vertices[0];
                writeln(format("first vertex: %.3f %.3f %.3f", first.x,
                    first.y, first.z));
            }
            size_t nonFinite;
            foreach (vertex; mesh.vertices)
                if (!isFinite(vertex.x) || !isFinite(vertex.y) ||
                    !isFinite(vertex.z))
                    ++nonFinite;
            writeln("non-finite vertices: ", nonFinite);
            size_t invalidFaces;
            foreach (face; mesh.faces)
                if (face.a < 0 || face.b < 0 || face.c < 0 ||
                    face.a >= mesh.vertices.length ||
                    face.b >= mesh.vertices.length ||
                    face.c >= mesh.vertices.length)
                    ++invalidFaces;
            writeln("invalid faces: ", invalidFaces);
            return 1;
        }
        const minimum = meshMinimum(mesh);
        const maximum = meshMaximum(mesh);
        writeln(format("human base mesh (%s): vertices=%d faces=%d",
            glbLoadPath.length > 0 ? "glb" :
            humanVersion == 1 ? "v1" : humanVersion == 2 ? "v2" : "v3",
            mesh.vertices.length, mesh.faces.length));
        if (hasGltfScene)
            writeln(format(
                "glb scene: nodes=%d meshes=%d materials=%d textures=%d images=%d skins=%d animations=%d",
                gltfScene.nodes.length, gltfScene.meshes.length,
                gltfScene.materials.length, gltfScene.textures.length,
                gltfScene.images.length, gltfScene.skins.length,
                gltfScene.animations.length));
        writeln(format("bounds: %.3f..%.3f x, %.3f..%.3f y, %.3f..%.3f z",
            minimum.x, maximum.x, minimum.y, maximum.y, minimum.z, maximum.z));
        writeln("obj round-trip: " ~
            (parseObj(toObj(mesh)).faces.length == mesh.faces.length ?
                "ok" : "mismatch"));
        writeln("watertight: " ~ (watertight(mesh) ? "yes" : "no"));
        const edges = meshEdgeStats(mesh);
        writeln("boundary edges: ", edges.boundary,
            ", non-manifold edges: ", edges.nonManifold);
        return 0;
    }

    if (exportPath.length > 0)
    {
        ensureParent(exportPath);
        write(exportPath, toObj(mesh));
        writeln("wrote " ~ exportPath);
        return 0;
    }

    if (glbExportPath.length > 0)
    {
        ensureParent(glbExportPath);
        try
            write(glbExportPath, hasGltfScene ? gltfScene.source :
                toGlb(mesh));
        catch (Exception error)
        {
            stderr.writeln("GLB export failed: " ~ error.msg);
            return 1;
        }
        writeln("wrote " ~ glbExportPath);
        return 0;
    }

    if (staticGlbExportPath.length > 0)
    {
        ensureParent(staticGlbExportPath);
        try
            write(staticGlbExportPath, toGlb(mesh));
        catch (Exception error)
        {
            stderr.writeln("Static GLB export failed: " ~ error.msg);
            return 1;
        }
        writeln("wrote " ~ staticGlbExportPath);
        return 0;
    }

    Camera camera;
    camera.focus(meshMinimum(mesh), meshMaximum(mesh));

    if (gpuInfo)
    {
        writeln(gpuAvailable() ? "vulkan: " ~ gpuDeviceName() :
            "vulkan: unavailable — " ~ gpuUnavailableReason());
        return 0;
    }

    if (probeArguments.length == 2)
    {
        string report;
        const ok = gpuProbeShaders(probeArguments[0], probeArguments[1],
            report);
        writeln((ok ? "shader accepted: " : "shader rejected: ") ~ report);
        return ok ? 0 : 1;
    }

    if (smokeRequested)
    {
        string report;
        const ok = gpuSmokeTest(report);
        writeln((ok ? "smoke aok: " : "smoke failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (pointSmokeRequested)
    {
        string report;
        const ok = gpuSmokePoint(report);
        writeln((ok ? "point aok: " : "point failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (auroraSmokeRequested)
    {
        string report;
        const ok = gpuSmokeAurora(report);
        writeln((ok ? "aurora aok: " : "aurora failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (pairSmokeRequested)
    {
        string report;
        const ok = gpuSmokePair(report);
        writeln((ok ? "pair aok: " : "pair failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (computeSmokeRequested)
    {
        string report;
        const ok = gpuSmokeCompute(report);
        writeln((ok ? "compute aok: " : "compute failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (indexSmokeRequested)
    {
        string report;
        const ok = gpuSmokeIndex(report);
        writeln((ok ? "index aok: " : "index failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (imageSmokeRequested)
    {
        string report;
        const ok = gpuSmokeImage(report);
        writeln((ok ? "image aok: " : "image failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (rasterSmokeRequested)
    {
        string report;
        const ok = gpuSmokeRaster(report);
        writeln((ok ? "raster aok: " : "raster failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (gpuSelfTestRequested)
    {
        string report;
        const ok = gpuSelfTest(report);
        writeln((ok ? "selftest ok: " : "selftest failed: ") ~ report);
        return ok ? 0 : 1;
    }

    if (benchRequested)
    {
        width = width < 64 ? 900 : width;
        height = height < 64 ? 700 : height;
        RenderOptions benchOptions;
        benchOptions.wireframe = false;
        benchOptions.vertices = false;
        useGpu(false);
        renderFrame(mesh, camera, width, height, benchOptions);
        auto clock = MonoTime.currTime();
        foreach (frameIndex; 0 .. benchFrames)
            renderFrame(mesh, camera, width, height, benchOptions);
        const softwareMs = (MonoTime.currTime() - clock).total!"usecs" /
            1000.0 / benchFrames;
        writeln(format("software: %.2f ms/frame", softwareMs));
        writeln(format("software phases: background %.2f, project %.2f, "
            ~ "raster %.2f ms", softwareStats.backgroundMs,
            softwareStats.projectMs, softwareStats.rasterMs));
        if (gpuAvailable())
        {
            useGpu(true);
            renderFrame(mesh, camera, width, height, benchOptions);
            clock = MonoTime.currTime();
            foreach (frameIndex; 0 .. benchFrames)
                renderFrame(mesh, camera, width, height, benchOptions);
            const gpuMs = (MonoTime.currTime() - clock).total!"usecs" /
                1000.0 / benchFrames;
            const stats = viewportStats();
            writeln(format(
                "vulkan: %.2f ms/frame (%s; upload %.2f, record %.2f, readback %.2f; %d draws, %d triangles)",
                gpuMs, viewportBackend(), stats.uploadMs, stats.drawMs,
                stats.readbackMs, stats.drawCalls, stats.triangles));
        }
        else
            writeln("vulkan: unavailable — " ~ gpuUnavailableReason());
        return 0;
    }

    if (renderPath.length > 0)
    {
        ensureParent(renderPath);
        width = width < 64 ? 640 : width;
        height = height < 64 ? 480 : height;
        auto options = RenderOptions();
        options.wireframe = false;
        options.vertices = false;
        const frame = renderFrame(mesh, camera, width, height, options);
        writePpm(renderPath, frame);
        const stats = viewportStats();
        writeln(format("wrote %s (%dx%d) via %s; %d draws, %d triangles",
            renderPath, width, height, viewportBackend(), stats.drawCalls,
            stats.triangles));
        return 0;
    }

    width = width < 640 ? 960 : width;
    height = height < 480 ? 640 : height;
    WindowOptions options;
    options.title = "Aurora Mesh · Human Base Mesh";
    options.width = width;
    options.height = height;
    options.darkTitleBar = true;
    options.alwaysOnTop = true;
    options.renderer = RendererPreference.vulkan;
    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new MeshEditor(mesh, objPath);
    editor.setLivePath(livePath);
    if (hasGltfScene)
        editor.setGltfScene(gltfScene, selectedAnimation, glbTime);
    window.setRoot(editor);
    editor.setRendererInfo(window.rendererName(), window.hardwareAccelerated(),
        window.rendererFallbackReason());

    if (screenshotPath.length > 0 || hasGltfScene)
    {
        if (screenshotPath.length > 0)
            ensureParent(screenshotPath);
        auto frames = 0;
        auto lastWake = MonoTime.currTime;
        window.applicationService = delegate(double delta)
        {
            const now = MonoTime.currTime;
            if (delta <= 0)
                delta = (now - lastWake).total!"seconds";
            lastWake = now;
            editor.tickLive();
            if (hasGltfScene)
                editor.advance(delta);
            frames++;
            if (screenshotPath.length > 0 && frames == 4)
            {
                window.saveScreenshot(screenshotPath);
                window.close();
            }
        };
        auto wake = new Thread(delegate()
        {
            try
            {
                write("build/driver-start.txt", "started");
                Thread.sleep(1.seconds);
                int heartbeat;
                while (true)
                {
                    Thread.sleep(16.msecs);
                    editor.tickLive();
                    if (hasGltfScene)
                        editor.advance(0.016);
                    editor.writeDriverState("build/driver-state.json");
                    window.serviceWake();
                    heartbeat++;
                    if (heartbeat % 60 == 0)
                        write("build/driver-heartbeat.txt",
                            format("%d", heartbeat));
                }
            }
            catch (Throwable error)
            {
                write("build/driver-error.txt", error.toString());
            }
        });
        wake.isDaemon = true;
        wake.start();
    }

    return window.run();
}

private void ensureParent(string path)
{
    const parent = dirName(path);
    if (parent.length > 0 && parent != ".")
        mkdirRecurse(parent);
}
