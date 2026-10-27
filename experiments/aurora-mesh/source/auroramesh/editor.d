module auroramesh.editor;

import auroramesh.camera : Camera, project;
import auroramesh.edit : pickNearest, screenDelta;
import auroramesh.glb : fromGlb, toGlb;
import auroramesh.gltf_scene : GltfScene, PoseOverride, bakeGltfFrame,
    gltfAnimationDuration, loadGltfScene;
import auroramesh.live : liveObject;
import auroramesh.mesh : Material, MaterialSlot, Mesh, Vec2, Vec3,
    meshAdd = add, humanBaseMesh, meshMaximum, meshMinimum, parseObj, toObj;
import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.human_v3 : humanBaseMeshV3;
import auroramesh.renderer : RgbFrame, RenderOptions, renderMesh;
import auroramesh.sculpt : cloneMesh, inflateVertices, mirrorVertex,
    smoothVertices;
import aurora : Canvas, Color, CursorKind, Event, HorizontalAlign, Key,
    MouseButton, Point, Rect, VerticalAlign, Widget;
import std.file : exists, read, readText, write;
import std.algorithm : max, min;
import std.conv : to;
import std.format : format;
import std.math : abs;
import std.json : JSONType, JSONValue, parseJSON;
import std.utf : toUTF32;

private enum int SidebarWidth = 300;
private enum int ButtonHeight = 34;
private enum int ButtonGap = 6;
private enum int BrushRadius = 42;
private enum string[] ButtonLabels = [
    "Human v3",
    "Human v2",
    "Human v1",
    "Reset view",
    "Wireframe",
    "Save OBJ",
    "Load OBJ",
    "Save GLB",
    "Load GLB",
];

/**
 * A small retained 3D viewport and edit surface.
 *
 * The editor is deliberately self-contained: a software projection and
 * z-buffered rasterizer feed an RGB image, while mouse and keyboard input edit
 * the mesh directly. No scene file or external renderer is involved.
 */
final class MeshEditor : Widget
{
    private Mesh _mesh;
    private Camera _camera;
    private string _objPath;
    private string _glbPath = "mesh.glb";
    private RgbFrame _frame;
    private int _frameWidth;
    private int _frameHeight;
    private bool _dirty = true;
    private bool _wireframe = false;
    private int _selected = -1;
    private int _axis;
    private bool _dragging;
    private bool _orbiting;
    private bool _panning;
    private Point _last;
    private string _status = "Human base mesh loaded";
    private int _hotButton = -1;
    private int _tool;
    private bool _symmetry;
    private Mesh[] _undo;
    private GltfScene _scene;
    private bool _hasScene;
    private int _animation;
    private double _time;
    private bool _playing;
    private PoseOverride[] _poseOverrides;
    private Mesh[] _liveExtras;
    private string _livePath = "build/live.json";
    private string _liveText;
    private long _liveRevision;
    private string _liveStatus;

    this(Mesh mesh, string objPath)
    {
        _mesh = mesh;
        _objPath = objPath;
        setFocusable(true);
        setCursor(CursorKind.crosshair);
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
    }

    Mesh mesh()
    {
        return _mesh;
    }

    Camera camera()
    {
        return _camera;
    }

    int selectedVertex() const
    {
        return _selected;
    }

    void setMesh(Mesh mesh)
    {
        _hasScene = false;
        _poseOverrides.length = 0;
        _liveExtras.length = 0;
        _liveStatus = "";
        _mesh = mesh;
        _undo.length = 0;
        _selected = -1;
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
        _dirty = true;
        _status = "Mesh loaded";
        invalidate();
    }

    void setGltfScene(GltfScene scene, int animation = 0, double time = 0)
    {
        _scene = scene;
        _hasScene = true;
        _animation = animation >= 0 && animation < _scene.animations.length ?
            animation : 0;
        _time = time;
        _playing = false;
        _poseOverrides.length = 0;
        _liveExtras.length = 0;
        _status = _scene.animations.length > 0 ?
            "GLB scene · " ~ _scene.animations[_animation].name :
            "GLB scene loaded";
        rebuildGltfMesh();
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
        invalidate();
    }

    void advance(double delta)
    {
        if (!_hasScene || !_playing || _scene.animations.length == 0)
            return;
        _time += delta;
        const duration = gltfAnimationDuration(_scene, _animation);
        if (duration > 0)
            while (_time > duration)
                _time -= duration;
        rebuildGltfMesh();
    }

    void setLivePath(string path)
    {
        _livePath = path;
    }

    void tickLive()
    {
        if (!_hasScene || _livePath.length == 0 || !exists(_livePath))
            return;
        string text;
        try
            text = readText(_livePath);
        catch (Exception)
            return;
        if (text == _liveText)
            return;
        _liveText = text;
        JSONValue document;
        try
            document = parseJSON(text);
        catch (Exception error)
        {
            _liveStatus = "Live JSON error";
            _status = _liveStatus;
            invalidate();
            return;
        }
        long revision;
        if (liveHas(document, "revision"))
            revision = liveInteger(document.object["revision"]);
        if (revision > 0 && revision == _liveRevision)
            return;
        _liveRevision = revision;
        const changed = applyLiveDocument(document);
        if (changed)
        {
            rebuildGltfMesh();
            _status = format("Live: %d object(s), %d pose override(s)",
                _liveExtras.length, _poseOverrides.length);
        }
        _liveStatus = "Live revision " ~ to!string(revision);
        try
            write("build/live-ack.json", format(
                `{"revision":%d,"status":"ok","objects":%d,"poses":%d}`,
                revision, _liveExtras.length, _poseOverrides.length));
        catch (Exception)
        {
        }
        invalidate();
    }

    private void rebuildGltfMesh()
    {
        if (!_hasScene)
            return;
        _mesh = bakeGltfFrame(_scene, _animation, _time, true,
            _poseOverrides);
        if (_liveExtras.length > 0)
        {
            foreach (extra; _liveExtras)
            {
                if (extra.vertices.length == 0)
                    continue;
                const offset = cast(int) _mesh.vertices.length;
                _mesh.vertices ~= extra.vertices;
                _mesh.normals ~= extra.normals;
                if (_mesh.uvs.length == offset)
                    foreach (vertex; extra.vertices)
                        _mesh.uvs ~= Vec2(0, 0);
                MaterialSlot slot;
                slot.baseColor = Vec3(0.66, 0.69, 0.74);
                slot.doubleSided = true;
                const materialIndex = cast(int) _mesh.materials.length;
                _mesh.materials ~= slot;
                foreach (face; extra.faces)
                {
                    const before = _mesh.faces.length;
                    _mesh.addTriangle(offset + face.a, offset + face.b,
                        offset + face.c, Material.neutral);
                    if (_mesh.faces.length > before)
                        _mesh.faceMaterials ~= materialIndex;
                }
            }
        }
        _dirty = true;
        invalidate();
    }

    private bool applyLiveDocument(JSONValue document)
    {
        bool changed;
        if (liveHas(document, "clear") &&
            document.object["clear"].type == JSONType.true_ &&
            document.object["clear"].boolean)
        {
            _liveExtras.length = 0;
            _poseOverrides.length = 0;
            changed = true;
        }
        const commands = liveChild(document, "commands");
        if (commands.type == JSONType.array)
            foreach (command; commands.array)
                changed = applyLiveCommand(command) || changed;
        else
            changed = applyLiveCommand(document) || changed;
        return changed;
    }

    private bool applyLiveCommand(JSONValue command)
    {
        const type = liveString(liveChild(command, "type"));
        if (type == "clear")
        {
            _liveExtras.length = 0;
            _poseOverrides.length = 0;
            return true;
        }
        if (type == "animation")
        {
            int index = -1;
            const name = liveString(liveChild(command, "name"));
            foreach (candidate, animation; _scene.animations)
                if (animation.name == name)
                {
                    index = cast(int) candidate;
                    break;
                }
            if (index < 0 && liveHas(command, "index"))
                index = cast(int) liveInteger(liveChild(command, "index"));
            if (index < 0 || index >= _scene.animations.length)
                return false;
            _animation = index;
            _time = liveNumber(liveChild(command, "time"));
            _playing = false;
            return true;
        }
        if (type == "time")
        {
            _time = liveNumber(liveChild(command, "time"));
            return true;
        }
        if (type == "object")
        {
            const shape = liveString(liveChild(command, "shape"), "box");
            const position = liveVector(liveChild(command, "position"),
                Vec3(0, 1.2, 0));
            const scale = liveNumber(liveChild(command, "scale"), 1.0);
            _liveExtras ~= liveObject(shape, position, scale);
            return true;
        }
        if (type == "pose")
        {
            const nodeName = liveString(liveChild(command, "node"));
            int node = -1;
            foreach (index, value; _scene.nodes)
                if (value.name == nodeName)
                {
                    node = cast(int) index;
                    break;
                }
            if (node < 0 && liveHas(command, "node"))
                node = cast(int) liveInteger(liveChild(command, "node"));
            if (node < 0 || node >= _scene.nodes.length)
                return false;
            if (liveHas(command, "reset") &&
                liveChild(command, "reset").type == JSONType.true_ &&
                liveChild(command, "reset").boolean)
            {
                foreach (index, overrideValue; _poseOverrides)
                    if (overrideValue.node == node)
                    {
                        _poseOverrides = _poseOverrides[0 .. index] ~
                            _poseOverrides[index + 1 .. $];
                        break;
                    }
                return true;
            }
            PoseOverride overrideValue;
            overrideValue.node = node;
            const translation = liveNumbers(liveChild(command, "translation"));
            if (translation.length >= 3)
            {
                overrideValue.hasTranslation = true;
                overrideValue.translation = Vec3(translation[0],
                    translation[1], translation[2]);
            }
            const rotation = liveNumbers(liveChild(command, "rotation"));
            if (rotation.length >= 4)
            {
                overrideValue.hasRotation = true;
                overrideValue.rotation = [rotation[0], rotation[1],
                    rotation[2], rotation[3]];
            }
            const scale = liveNumbers(liveChild(command, "scale"));
            if (scale.length >= 3)
            {
                overrideValue.hasScale = true;
                overrideValue.scale = Vec3(scale[0], scale[1], scale[2]);
            }
            if (!overrideValue.hasTranslation && !overrideValue.hasRotation &&
                !overrideValue.hasScale)
                return false;
            bool replaced;
            foreach (ref existing; _poseOverrides)
                if (existing.node == node)
                {
                    existing = overrideValue;
                    replaced = true;
                    break;
                }
            if (!replaced)
                _poseOverrides ~= overrideValue;
            return true;
        }
        return false;
    }

    private static bool liveHas(JSONValue value, string key)
    {
        return value.type == JSONType.object && (key in value.object);
    }

    private static JSONValue liveChild(JSONValue value, string key)
    {
        if (!liveHas(value, key))
            return JSONValue();
        return value.object[key];
    }

    private static string liveString(JSONValue value, string fallback = "")
    {
        return value.type == JSONType.string ? value.str : fallback;
    }

    private static double liveNumber(JSONValue value, double fallback = 0)
    {
        switch (value.type)
        {
            case JSONType.integer:
                return cast(double) value.integer;
            case JSONType.uinteger:
                return cast(double) value.uinteger;
            case JSONType.float_:
                return value.floating;
            default:
                return fallback;
        }
    }

    private static long liveInteger(JSONValue value)
    {
        return value.type == JSONType.integer ? value.integer :
            value.type == JSONType.uinteger ? cast(long) value.uinteger : 0;
    }

    private static double[] liveNumbers(JSONValue value)
    {
        double[] result;
        if (value.type != JSONType.array)
            return result;
        foreach (item; value.array)
            result ~= liveNumber(item);
        return result;
    }

    private static Vec3 liveVector(JSONValue value, Vec3 fallback)
    {
        const values = liveNumbers(value);
        return values.length >= 3 ? Vec3(values[0], values[1], values[2]) :
            fallback;
    }

    override protected void onPaint(ref Canvas canvas)
    {
        const width = max(1, bounds().width);
        const height = max(1, bounds().height);
        const viewportWidth = max(1, width - SidebarWidth);
        const viewportHeight = max(1, height);

        if (_frame.pixels.length == 0 || _frameWidth != viewportWidth ||
            _frameHeight != viewportHeight || _dirty)
        {
            RenderOptions options;
            options.wireframe = _wireframe;
            options.vertices = _wireframe;
            options.selectedVertex = _selected;
            _frame = renderMesh(_mesh, _camera, viewportWidth, viewportHeight,
                options);
            _frameWidth = viewportWidth;
            _frameHeight = viewportHeight;
            _dirty = false;
        }

        canvas.drawRgbImage(Rect(0, 0, viewportWidth, viewportHeight),
            _frame.width, _frame.height, _frame.pixels, false);
        canvas.fillRect(Rect(viewportWidth, 0, 1, height),
            Color.rgba(45, 212, 191, 90));

        const pad = 18;
        const sidebarX = viewportWidth;
        canvas.fillRect(Rect(sidebarX, 0, SidebarWidth, height),
            Color.rgba(13, 21, 36, 255));
        canvas.fillRect(Rect(sidebarX, 0, SidebarWidth, 3),
            Color.rgba(45, 212, 191, 255));

        const left = sidebarX + pad;
        const inner = SidebarWidth - pad * 2;
        const white = Color.rgba(226, 232, 240, 255);
        const muted = Color.rgba(148, 163, 184, 255);
        const accent = Color.rgba(45, 212, 191, 255);
        const warn = Color.rgba(251, 146, 60, 255);
        label(canvas, Rect(left, 22, inner, 28), "AURORA MESH", white, 2);
        label(canvas, Rect(left, 52, inner, 22),
            "Human base mesh · software 3D", muted, 1);

        label(canvas, Rect(left, 90, inner, 20),
            format("VERTICES  %d", _mesh.vertices.length), white, 1);
        label(canvas, Rect(left, 112, inner, 20),
            format("FACES  %d", _mesh.faces.length), white, 1);
        if (_selected >= 0 && _selected < _mesh.vertices.length)
        {
            const vertex = _mesh.vertices[_selected];
            label(canvas, Rect(left, 134, inner, 20),
                format("V%d  %.2f  %.2f  %.2f", _selected, vertex.x, vertex.y,
                    vertex.z), warn, 1);
        }
        else
            label(canvas, Rect(left, 134, inner, 20),
                "No vertex selected", muted, 1);
        label(canvas, Rect(left, 156, inner, 20),
            _axis == 0 ? "AXIS  free" :
            _axis == 1 ? "AXIS  X" : _axis == 2 ? "AXIS  Y" : "AXIS  Z",
            _axis == 0 ? muted : accent, 1);
        label(canvas, Rect(left, 176, inner, 20),
            format("TOOL  %s%s", toolName(), _symmetry ? " · mirror X" : ""),
            _symmetry ? accent : white, 1);
        if (_hasScene && _scene.animations.length > 0)
            label(canvas, Rect(left, 196, inner, 20),
                format("ANIM  %s  %.2fs%s",
                    _scene.animations[_animation].name, _time,
                    _playing ? "  playing" : "  paused"), accent, 1);

        label(canvas, Rect(left, 218, inner, 20), "CONTROLS", muted, 1);
        immutable string[] help = [
            "Drag empty: orbit",
            "Drag vertex: move",
            "Right / middle: pan",
            "Wheel: zoom",
            "X / Y / Z: axis lock",
            "Esc: free · R: reset",
            "B: tool · M: symmetry",
            "U: undo",
            "W wire · S/L OBJ · G/F GLB",
        ];
        foreach (index, line; help)
            label(canvas, Rect(left, 240 + cast(int) index * 20, inner, 20), line,
                white, 1);

        const buttons = buttonRects();
        foreach (index, rect; buttons)
        {
            const hot = cast(int) index == _hotButton;
            canvas.fillRoundedRect(rect, 7,
                hot ? Color.rgba(30, 62, 75, 255) :
                Color.rgba(20, 34, 52, 255));
            canvas.drawRoundedRect(rect, 7,
                hot ? Color.rgba(30, 62, 75, 255) :
                Color.rgba(20, 34, 52, 255),
                hot ? Color.rgba(45, 212, 191, 180) :
                Color.rgba(71, 85, 105, 160), 1);
            label(canvas, rect, ButtonLabels[index],
                hot ? white : Color.rgba(203, 213, 225, 255), 1,
                HorizontalAlign.center);
        }

        const statusY = buttons.length > 0 ? buttons[0].y - 26 : height - 34;
        label(canvas, Rect(left, statusY, inner, 20), _status, muted, 1);
        label(canvas, Rect(14, 12, 260, 22),
            "PERSPECTIVE · SOFTWARE 3D", Color.rgba(148, 163, 184, 210), 1);
    }

    private Rect[] buttonRects() const
    {
        const width = max(1, bounds().width);
        const height = max(1, bounds().height);
        const left = width - SidebarWidth + 18;
        const inner = SidebarWidth - 36;
        const int count = cast(int) ButtonLabels.length;
        const int total = count * (ButtonHeight + ButtonGap);
        const int top = max(300, height - total - 48);
        Rect[] result;
        foreach (index; 0 .. count)
            result ~= Rect(left,
                top + index * (ButtonHeight + ButtonGap),
                inner, ButtonHeight);
        return result;
    }

    private int buttonAt(Point point)
    {
        foreach (index, rect; buttonRects())
            if (rect.contains(point))
                return cast(int) index;
        return -1;
    }

    override bool onMouseDown(ref Event event)
    {
        requestFocus();
        const width = max(1, bounds().width);
        const viewportWidth = max(1, width - SidebarWidth);
        if (event.position.x >= viewportWidth)
        {
            const button = buttonAt(event.position);
            if (button >= 0)
            {
                performButton(button);
                return true;
            }
            return true;
        }

        if (event.button == MouseButton.left)
        {
            if (_tool != 0)
            {
                pushUndo();
                _dragging = true;
                _last = event.position;
                applyBrush(event.position);
                captureMouse();
                return true;
            }
            const picked = pickNearest(_mesh, _camera,
                max(1, bounds().width - SidebarWidth), max(1, bounds().height),
                event.position.x, event.position.y);
            if (picked >= 0)
            {
                pushUndo();
                _selected = picked;
                _dragging = true;
                _status = format("Selected vertex %d", picked);
            }
            else
            {
                _orbiting = true;
            }
            _last = event.position;
            captureMouse();
            _dirty = true;
            invalidate();
            return true;
        }
        if (event.button == MouseButton.right ||
            event.button == MouseButton.middle)
        {
            _panning = true;
            _last = event.position;
            captureMouse();
            return true;
        }
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        const dx = event.position.x - _last.x;
        const dy = event.position.y - _last.y;
        if (_dragging && _tool != 0)
        {
            applyBrush(event.position);
        }
        else if (_dragging && _selected >= 0 &&
            _selected < _mesh.vertices.length)
        {
            const height = max(1, bounds().height);
            auto offset = screenDelta(_camera, height, dx, dy, _axis);
            const mirrored = _symmetry ?
                mirrorVertex(_mesh, _selected) : -1;
            _mesh.vertices[_selected] = meshAdd(_mesh.vertices[_selected],
                offset);
            if (mirrored >= 0 && mirrored != _selected)
                _mesh.vertices[mirrored] = meshAdd(_mesh.vertices[mirrored],
                    Vec3(-offset.x, offset.y, offset.z));
            const vertex = _mesh.vertices[_selected];
            _status = format("V%d  %.2f  %.2f  %.2f", _selected, vertex.x,
                vertex.y, vertex.z);
            _dirty = true;
            invalidate();
        }
        else if (_orbiting)
        {
            _camera.orbit(dx, dy);
            _dirty = true;
            invalidate();
        }
        else if (_panning)
        {
            _camera.pan(dx, dy, max(1, bounds().height));
            _dirty = true;
            invalidate();
        }
        else if (event.position.x >= max(1, bounds().width - SidebarWidth))
        {
            const hot = buttonAt(event.position);
            if (hot != _hotButton)
            {
                _hotButton = hot;
                invalidate();
            }
        }
        _last = event.position;
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (_dragging || _orbiting || _panning)
            releaseMouse();
        _dragging = false;
        _orbiting = false;
        _panning = false;
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        const viewportWidth = max(1, bounds().width - SidebarWidth);
        if (event.position.x < viewportWidth)
        {
            _camera.zoom(event.wheelY);
            _dirty = true;
            invalidate();
            return true;
        }
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        switch (event.key)
        {
            case Key.h:
                setMesh(humanBaseMeshV3());
                _status = "Human v3 regenerated";
                return true;
            case Key.v:
                setMesh(humanBaseMeshV2());
                _status = "Human v2 loaded";
                return true;
            case Key.digit1:
                setMesh(humanBaseMesh());
                _status = "Human v1 loaded";
                return true;
            case Key.digit2:
                setMesh(humanBaseMeshV2());
                _status = "Human v2 loaded";
                return true;
            case Key.digit3:
                setMesh(humanBaseMeshV3());
                _status = "Human v3 loaded";
                return true;
            case Key.b:
                _tool = (_tool + 1) % 3;
                _status = "Sculpt tool: " ~ toolName();
                invalidate();
                return true;
            case Key.m:
                _symmetry = !_symmetry;
                _status = _symmetry ? "Mirror X on" : "Mirror X off";
                invalidate();
                return true;
            case Key.u:
                undoLast();
                return true;
            case Key.r:
                _camera.reset();
                _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
                _dirty = true;
                _status = "View reset";
                invalidate();
                return true;
            case Key.w:
                _wireframe = !_wireframe;
                _dirty = true;
                _status = _wireframe ? "Wireframe on" : "Wireframe off";
                invalidate();
                return true;
            case Key.s:
                saveObj();
                return true;
            case Key.l:
                loadObj();
                return true;
            case Key.g:
                saveGlb();
                return true;
            case Key.f:
                loadGlb();
                return true;
            case Key.x:
                _axis = _axis == 1 ? 0 : 1;
                _status = _axis == 1 ? "Axis: X" : "Axis: free";
                invalidate();
                return true;
            case Key.y:
                _axis = _axis == 2 ? 0 : 2;
                _status = _axis == 2 ? "Axis: Y" : "Axis: free";
                invalidate();
                return true;
            case Key.z:
                _axis = _axis == 3 ? 0 : 3;
                _status = _axis == 3 ? "Axis: Z" : "Axis: free";
                invalidate();
                return true;
            case Key.space:
                if (_hasScene && _scene.animations.length > 0)
                {
                    _playing = !_playing;
                    _status = _playing ? "Playing " ~
                        _scene.animations[_animation].name :
                        "Animation paused";
                    invalidate();
                    return true;
                }
                return false;
            case Key.n:
                if (_hasScene && _scene.animations.length > 0)
                {
                    _animation = (_animation + 1) %
                        cast(int) _scene.animations.length;
                    _time = 0;
                    rebuildGltfMesh();
                    _status = "Animation: " ~
                        _scene.animations[_animation].name;
                    invalidate();
                    return true;
                }
                return false;
            case Key.leftBracket:
            case Key.rightBracket:
                if (_hasScene && _scene.animations.length > 0)
                {
                    _time += event.key == Key.leftBracket ? -0.1 : 0.1;
                    const duration = gltfAnimationDuration(_scene, _animation);
                    if (duration > 0)
                        while (_time < 0)
                            _time += duration;
                    rebuildGltfMesh();
                    _status = format("Animation time %.2fs", _time);
                    invalidate();
                    return true;
                }
                return false;
            case Key.escape:
                _selected = -1;
                _axis = 0;
                _status = "Selection cleared";
                _dirty = true;
                invalidate();
                return true;
            default:
                return false;
        }
    }

    private void performButton(int button)
    {
        switch (button)
        {
            case 0:
                setMesh(humanBaseMeshV3());
                _status = "Human v3 regenerated";
                break;
            case 1:
                setMesh(humanBaseMeshV2());
                _status = "Human v2 regenerated";
                break;
            case 2:
                setMesh(humanBaseMesh());
                _status = "Human v1 loaded";
                break;
            case 3:
                _camera.reset();
                _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
                _dirty = true;
                _status = "View reset";
                break;
            case 4:
                _wireframe = !_wireframe;
                _dirty = true;
                _status = _wireframe ? "Wireframe on" : "Wireframe off";
                break;
            case 5:
                saveObj();
                break;
            case 6:
                loadObj();
                break;
            case 7:
                saveGlb();
                break;
            case 8:
                loadGlb();
                break;
            default:
                break;
        }
        invalidate();
    }


    private void saveObj()
    {
        try
        {
            write(_objPath, toObj(_mesh));
            _status = "Saved " ~ _objPath;
        }
        catch (Exception error)
            _status = "Save failed: " ~ error.msg;
        invalidate();
    }

    private void loadObj()
    {
        try
        {
            if (!exists(_objPath))
            {
                _status = "No OBJ at " ~ _objPath;
                invalidate();
                return;
            }
            auto loaded = parseObj(readText(_objPath));
            if (loaded.vertices.length == 0)
            {
                _status = "OBJ has no vertices";
                invalidate();
                return;
            }
            setMesh(loaded);
            _status = "Loaded " ~ _objPath;
        }
        catch (Exception error)
            _status = "Load failed: " ~ error.msg;
        invalidate();
    }

    private void saveGlb()
    {
        try
        {
            if (_hasScene && _scene.source.length > 0)
            {
                write(_glbPath, _scene.source);
                _status = "Saved original GLB scene " ~ _glbPath;
            }
            else
            {
                write(_glbPath, toGlb(_mesh));
                _status = "Saved " ~ _glbPath;
            }
        }
        catch (Exception error)
            _status = "GLB save failed: " ~ error.msg;
        invalidate();
    }

    private void loadGlb()
    {
        try
        {
            if (!exists(_glbPath))
            {
                _status = "No GLB at " ~ _glbPath;
                invalidate();
                return;
            }
            auto scene = loadGltfScene(cast(ubyte[]) read(_glbPath));
            if (scene.meshes.length == 0)
            {
                _status = "GLB has no meshes";
                invalidate();
                return;
            }
            setGltfScene(scene);
            _status = "Loaded " ~ _glbPath;
        }
        catch (Exception error)
            _status = "GLB load failed: " ~ error.msg;
        invalidate();
    }

    private string toolName() const
    {
        return _tool == 0 ? "grab" : _tool == 1 ? "smooth" : "inflate";
    }

    private void pushUndo()
    {
        if (_undo.length >= 16)
            _undo = _undo[1 .. $];
        _undo ~= cloneMesh(_mesh);
    }

    private void undoLast()
    {
        if (_undo.length == 0)
        {
            _status = "Nothing to undo";
            invalidate();
            return;
        }
        _mesh = _undo[$ - 1];
        _undo = _undo[0 .. $ - 1];
        _selected = -1;
        _dirty = true;
        _status = "Undo";
        invalidate();
    }

    private void applyBrush(Point point)
    {
        const width = max(1, bounds().width - SidebarWidth);
        const height = max(1, bounds().height);
        int[] selected;
        foreach (index, vertex; _mesh.vertices)
        {
            const projected = project(vertex, _camera, width, height);
            if (!projected.visible)
                continue;
            const dx = projected.x - point.x;
            const dy = projected.y - point.y;
            if (dx * dx + dy * dy <= BrushRadius * BrushRadius)
                selected ~= cast(int) index;
        }
        if (_symmetry)
        {
            const original = selected.dup;
            foreach (index; original)
            {
                const mirrored = mirrorVertex(_mesh, index);
                if (mirrored >= 0 && mirrored != index)
                    selected ~= mirrored;
            }
        }
        if (selected.length == 0)
            return;
        if (_tool == 1)
            smoothVertices(_mesh, selected, 0.30);
        else if (_tool == 2)
            inflateVertices(_mesh, selected, 0.006);
        _dirty = true;
        _status = format("%s  %d vertices", toolName(), selected.length);
        invalidate();
    }

    private void label(Canvas canvas, Rect rect, string text, Color color,
        int scale = 1, HorizontalAlign alignment = HorizontalAlign.left)
    {
        canvas.drawTextInRect(rect, toUTF32(text), color, scale, alignment,
            VerticalAlign.middle, true);
    }
}
