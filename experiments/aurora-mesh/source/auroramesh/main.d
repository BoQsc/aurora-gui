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
import auroramesh.gltf_scene : GltfScene, bakeGltfFrame, loadGltfScene;
import auroramesh.renderer : RenderOptions, renderMesh, writePpm;
import aurora : GuiWindow, Theme, WindowOptions;
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
    writeln("  aurora-mesh --check                  validate and print mesh statistics");
    writeln("  aurora-mesh --export-obj <file.obj>  write the human base mesh");
    writeln("  aurora-mesh --export-glb <file.glb>  write a glTF 2.0 binary mesh");
    writeln("  aurora-mesh --export-static-glb <file.glb>  bake textures/UVs into a static GLB");
    writeln("  aurora-mesh --obj <file.obj>         load a mesh into the editor");
    writeln("  aurora-mesh --glb <file.glb>         load a GLB mesh into the editor");
    writeln("  --glb-anim <name|index>              select a GLB animation clip");
    writeln("  --glb-time <seconds>                 set the GLB animation time");
    writeln("  --glb-morph                          enable animated morph weights");
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
    GltfScene gltfScene;
    bool hasGltfScene;
    string glbAnimation;
    double glbTime;
    int selectedAnimation;
    bool noMorph;
    string screenshotPath;
    string objPath = "mesh.obj";
    bool check;
    int humanVersion = 3;
    int width = 1400;
    int height = 860;

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

    if (renderPath.length > 0)
    {
        ensureParent(renderPath);
        width = width < 64 ? 640 : width;
        height = height < 64 ? 480 : height;
        auto options = RenderOptions();
        options.wireframe = false;
        options.vertices = false;
        const frame = renderMesh(mesh, camera, width, height, options);
        writePpm(renderPath, frame);
        writeln(format("wrote %s (%dx%d)", renderPath, width, height));
        return 0;
    }

    width = width < 640 ? 960 : width;
    height = height < 480 ? 640 : height;
    WindowOptions options;
    options.title = "Aurora Mesh · Human Base Mesh";
    options.width = width;
    options.height = height;
    options.darkTitleBar = true;
    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new MeshEditor(mesh, objPath);
    if (hasGltfScene)
        editor.setGltfScene(gltfScene, selectedAnimation, glbTime);
    window.setRoot(editor);

    if (screenshotPath.length > 0 || hasGltfScene)
    {
        ensureParent(screenshotPath);
        auto frames = 0;
        window.applicationService = delegate(double delta)
        {
            if (hasGltfScene)
                editor.advance(delta);
            frames++;
            if (screenshotPath.length > 0 && frames == 4)
            {
                window.saveScreenshot(screenshotPath);
                window.close();
            }
        };
    }

    return window.run();
}

private void ensureParent(string path)
{
    const parent = dirName(path);
    if (parent.length > 0 && parent != ".")
        mkdirRecurse(parent);
}
