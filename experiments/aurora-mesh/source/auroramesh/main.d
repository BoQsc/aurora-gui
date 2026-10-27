module auroramesh.main;

version (Windows)
    import auroramesh.crt.msvcrt_shim;

import auroramesh.camera : Camera;
import auroramesh.editor : MeshEditor;
import auroramesh.mesh : Mesh, humanBaseMesh, meshMaximum, meshMinimum, parseObj,
    toObj, validMesh;
import auroramesh.renderer : RenderOptions, renderMesh, writePpm;
import aurora : GuiWindow, Theme, WindowOptions;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.format : format;
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
    writeln("  aurora-mesh --obj <file.obj>         load a mesh into the editor");
    writeln("  options: --width <pixels> --height <pixels>");
}

int main(string[] args)
{
    string renderPath;
    string exportPath;
    string loadPath;
    string screenshotPath;
    string objPath = "mesh.obj";
    bool check;
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
            case "--obj":
                if (++index >= args.length)
                {
                    stderr.writeln("--obj needs a path");
                    return 2;
                }
                loadPath = args[index];
                objPath = loadPath;
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
            default:
                stderr.writeln("unknown option: " ~ args[index]);
                usage();
                return 2;
        }
    }

    Mesh mesh = humanBaseMesh();
    if (loadPath.length > 0)
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
        if (loadPath.length == 0 && (mesh.vertices.length < 100 ||
            mesh.faces.length < 100))
        {
            stderr.writeln("human mesh is unexpectedly small");
            return 1;
        }
        if (!validMesh(mesh))
        {
            stderr.writeln("mesh validation failed");
            return 1;
        }
        const minimum = meshMinimum(mesh);
        const maximum = meshMaximum(mesh);
        writeln(format("human base mesh: vertices=%d faces=%d",
            mesh.vertices.length, mesh.faces.length));
        writeln(format("bounds: %.3f..%.3f x, %.3f..%.3f y, %.3f..%.3f z",
            minimum.x, maximum.x, minimum.y, maximum.y, minimum.z, maximum.z));
        writeln("obj round-trip: " ~
            (parseObj(toObj(mesh)).faces.length == mesh.faces.length ?
                "ok" : "mismatch"));
        return 0;
    }

    if (exportPath.length > 0)
    {
        ensureParent(exportPath);
        write(exportPath, toObj(mesh));
        writeln("wrote " ~ exportPath);
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
    window.setRoot(editor);

    if (screenshotPath.length > 0)
    {
        ensureParent(screenshotPath);
        auto frames = 0;
        window.applicationService = delegate(double delta)
        {
            frames++;
            if (frames == 4)
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
