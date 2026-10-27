module auroramesh.editor;

import auroramesh.camera : Camera, project;
import auroramesh.edit : pickNearest, screenDelta;
import auroramesh.glb : fromGlb, toGlb;
import auroramesh.gltf_scene : GltfScene, bakeGltfFrame,
    gltfAnimationDuration, loadGltfScene;
import auroramesh.mesh : Mesh, Vec3, meshAdd = add, humanBaseMesh,
    meshMaximum, meshMinimum, parseObj, toObj;
import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.human_v3 : humanBaseMeshV3;
import auroramesh.renderer : RgbFrame, RenderOptions, renderMesh;
import auroramesh.sculpt : cloneMesh, inflateVertices, mirrorVertex,
    smoothVertices;
import aurora : Canvas, Color, CursorKind, Event, HorizontalAlign, Key,
    MouseButton, Point, Rect, VerticalAlign, Widget;
import std.file : exists, read, readText, write;
import std.algorithm : max, min;
import std.format : format;
import std.math : abs;
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
        _mesh = bakeGltfFrame(_scene, _animation, _time, false);
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
        _status = _scene.animations.length > 0 ?
            "GLB scene · " ~ _scene.animations[_animation].name :
            "GLB scene loaded";
        _dirty = true;
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
        _mesh = bakeGltfFrame(_scene, _animation, _time, false);
        _dirty = true;
        invalidate();
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
                    _mesh = bakeGltfFrame(_scene, _animation, _time, false);
                    _dirty = true;
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
                    _mesh = bakeGltfFrame(_scene, _animation, _time, false);
                    _dirty = true;
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
