module auroramesh.editor;

import auroramesh.camera : Camera;
import auroramesh.edit : pickNearest, screenDelta;
import auroramesh.mesh : Mesh, meshAdd = add, humanBaseMesh, meshMaximum,
    meshMinimum, parseObj, toObj;
import auroramesh.renderer : RgbFrame, RenderOptions, renderMesh;
import aurora : Canvas, Color, CursorKind, Event, HorizontalAlign, Key,
    MouseButton, Point, Rect, VerticalAlign, Widget;
import std.file : exists, readText, write;
import std.algorithm : max, min;
import std.format : format;
import std.math : abs;
import std.utf : toUTF32;

private enum int SidebarWidth = 300;
private enum int ButtonHeight = 38;
private enum int ButtonGap = 8;
private enum string[] ButtonLabels = [
    "Human base",
    "Reset view",
    "Wireframe",
    "Save OBJ",
    "Load OBJ",
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
        _mesh = mesh;
        _selected = -1;
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
        _dirty = true;
        _status = "Mesh loaded";
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

        label(canvas, Rect(left, 194, inner, 20), "CONTROLS", muted, 1);
        immutable string[] help = [
            "Drag empty: orbit",
            "Drag vertex: move",
            "Right / middle: pan",
            "Wheel: zoom",
            "X / Y / Z: axis lock",
            "Esc: free · R: reset",
            "W: wire · S/L: OBJ",
        ];
        foreach (index, line; help)
            label(canvas, Rect(left, 216 + cast(int) index * 22, inner, 20), line,
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
            const picked = pickNearest(_mesh, _camera,
                max(1, bounds().width - SidebarWidth), max(1, bounds().height),
                event.position.x, event.position.y);
            if (picked >= 0)
            {
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
        if (_dragging && _selected >= 0 &&
            _selected < _mesh.vertices.length)
        {
            const height = max(1, bounds().height);
            auto offset = screenDelta(_camera, height, dx, dy, _axis);
            _mesh.vertices[_selected] = meshAdd(_mesh.vertices[_selected],
                offset);
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
                setMesh(humanBaseMesh());
                _status = "Human base mesh regenerated";
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
                setMesh(humanBaseMesh());
                _status = "Human base mesh regenerated";
                break;
            case 1:
                _camera.reset();
                _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
                _dirty = true;
                _status = "View reset";
                break;
            case 2:
                _wireframe = !_wireframe;
                _dirty = true;
                _status = _wireframe ? "Wireframe on" : "Wireframe off";
                break;
            case 3:
                saveObj();
                break;
            case 4:
                loadObj();
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

    private void label(Canvas canvas, Rect rect, string text, Color color,
        int scale = 1, HorizontalAlign alignment = HorizontalAlign.left)
    {
        canvas.drawTextInRect(rect, toUTF32(text), color, scale, alignment,
            VerticalAlign.middle, true);
    }
}
