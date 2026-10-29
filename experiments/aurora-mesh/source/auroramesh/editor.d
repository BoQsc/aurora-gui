module auroramesh.editor;

import auroramesh.camera : Camera, project;
import auroramesh.collision : CollisionReport, collisionClusters,
    findSelfIntersections;
import auroramesh.edit : brushVertices, pickNearest, screenDelta;
import auroramesh.glb : fromGlb, toGlb;
import auroramesh.gltf_scene : GltfScene, Mat4, PoseOverride, bakeGltfFrame,
    gltfAnimationDuration, gltfRotateVector, gltfTransformNormal,
    gltfTransformPoint, loadGltfScene;
import auroramesh.live : liveObject;
import auroramesh.mesh : Material, MaterialSlot, Mesh, Vec2, Vec3,
    meshAdd = add, computeSmoothNormals, meshCross = cross, dot,
    humanBaseMesh, length, meshMaximum, meshMinimum, normalize,
    meshScale = scale, parseObj, toObj;
import auroramesh.human_v2 : humanBaseMeshV2;
import auroramesh.human_v3 : humanBaseMeshV3;
import auroramesh.renderer : RgbFrame, RenderOptions, renderMesh, writePpm;
import auroramesh.reshape : RegionBox, RegionEdit, regionBox, regionVertices,
    reshapeBox, reshapeRegion;
import auroramesh.regions : RegionKind, RegionVolume, deformRegion, regionMask,
    selectRegion;
import auroramesh.remesh : addSdfShell, decimateTo, replaceChecked,
    subdivideMesh;
import auroramesh.sdf : SdfField, SdfShape, ellipsoid, sphere, taper;
import core.time : MonoTime;
import auroramesh.sculpt : cloneMesh, inflateVertices, mirrorVertex,
    smoothVertices;
import aurora : Canvas, Color, CursorKind, Event, HorizontalAlign, Key,
    MouseButton, Point, Rect, VerticalAlign, Widget;
import core.sync.mutex : Mutex;
import std.file : exists, read, readText, stdRemove = remove, rename, write;
import std.algorithm : filter, max, min, sort;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.math : abs, cos, isFinite, sin, sqrt;
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
    "Feet",
    "Boots",
];

private struct LiveExtra
{
    Mesh mesh;
    int node = -1;
    Vec3 offset;
    double[4] rotation = [0, 0, 0, 1];
    bool hasRotation;
    Vec3 color = Vec3(0.66, 0.69, 0.74);
}

private struct LiveKey
{
    double time;
    bool hasTranslation;
    Vec3 translation;
    bool hasRotation;
    double[4] rotation = [0, 0, 0, 1];
    /// Set when the key was authored as a world axis spin, so followers can
    /// reproduce the same motion.
    bool hasWorldAxis;
    Vec3 worldAxis = Vec3(1, 0, 0);
    double worldAngle;
    bool hasScale;
    Vec3 scale;
}

private struct LiveTrack
{
    int node = -1;
    LiveKey[] keys;
}

private struct LiveClip
{
    string name;
    double duration;
    bool loop = true;
    bool additive;
    LiveTrack[] tracks;
}

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
    private bool _cull = true;
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
    private LiveExtra[] _liveExtras;
    private string _livePath = "build/live.json";
    private string _liveText;
    private long _liveRevision;
    private string _liveStatus;
    private string _pendingSavePath;
    private LiveClip _liveClip;
    private bool _hasLiveAnimation;
    private CollisionReport _collisions;
    private bool _checkCollisions;
    private bool[ulong] _baselineCollisionKeys;
    private int _baselineCollisionCount;
    private int _auditNonFinite;
    private int _auditInvalidFaces;
    private string[] _auditWarnings;
    private bool _auditValid = true;
    private int _scanFrameCount;
    private int _scanInvalidFrames;
    private int _scanLimbHits;
    private bool _scanCollisions;
    private int _scanCollisionFrames;
    private int _scanCollisionPairs;
    private bool _scanRequested;
    private bool _scanIncremental;
    private bool _scanRunning;
    private bool _scanCancelRequested;
    private int _scanCursor;
    private string _scanReport;
    private double _scanRestoreTime;
    private int _scanLeftHand;
    private int _scanRightHand;
    private int _scanLeftForeArm;
    private int _scanRightForeArm;
    private int _scanHips;
    private int _scanNeck;
    private int _scanHead;
    private string[] _scanIgnorePartNames;
    private bool[int] _scanIgnoredParts;
    private Vec3 _scanPreviousLeft;
    private Vec3 _scanPreviousRight;
    private bool _scanHavePrevious;
    private int _scanTickCount;
    private int _scanAdvanceCount;
    private Mat4[] _nodeWorlds;
    private int _inspectNode = -1;
    private string _capturePath;
    private string _lastCapturePath;
    private string _rendererName = "unknown";
    private bool _rendererHardware;
    private string _rendererFallback;
    private string _sheetPath;
    private string _lastSheetPath;
    private bool _listBones;
    private int _liveFollowCount;
    private int[] _baselineClusters;
    private bool[ulong] _baselineRegions;
    private int _baselineClusterFaces;
    private int _baselineStrayFaces;
    private bool[int] _baselineStrayParts;
    /**
     * The window callback and the headless driver thread both drive live
     * authoring, so a tick must read, author, bake, audit and report as one
     * step; otherwise reports and frame scans interleave.
     */
    private shared Mutex _liveMutex;

    this(Mesh mesh, string objPath)
    {
        _liveMutex = new shared Mutex;
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
        _hasLiveAnimation = false;
        _liveClip = LiveClip();
        _poseOverrides.length = 0;
        _liveExtras.length = 0;
        _baselineCollisionKeys = null;
        _baselineCollisionCount = 0;
        buildCollisionBaseline();
        _liveStatus = "";
        _mesh = mesh;
        _undo.length = 0;
        _reshapecs.length = 0;
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
        _hasLiveAnimation = false;
        _liveClip = LiveClip();
        _poseOverrides.length = 0;
        _liveExtras.length = 0;
        buildCollisionBaselineAt(_time);
        _status = _scene.animations.length > 0 ?
            "GLB scene · " ~ _scene.animations[_animation].name :
            "GLB scene loaded";
        rebuildGltfMesh();
        _camera.focus(meshMinimum(_mesh), meshMaximum(_mesh));
        invalidate();
    }

    void advance(double delta)
    {
        synchronized (_liveMutex)
            advanceLocked(delta);
    }

    private void advanceLocked(double delta)
    {
        if (_hasLiveAnimation)
        {
            if (!_playing)
                return;
            _time += delta;
            if (_liveClip.duration > 0)
            {
                if (_liveClip.loop)
                    while (_time >= _liveClip.duration)
                        _time -= _liveClip.duration;
                else if (_time > _liveClip.duration)
                    _time = _liveClip.duration;
            }
            rebuildGltfMesh();
            invalidate();
            return;
        }
        if (!_hasScene || !_playing || _scene.animations.length == 0)
            return;
        _time += delta;
        const duration = gltfAnimationDuration(_scene, _animation);
        if (duration > 0)
        while (_time > duration)
            _time -= duration;
        rebuildGltfMesh();
        invalidate();
    }

    private static double[4] normalizeRotation(double[4] value)
    {
        const magnitude = sqrt(value[0] * value[0] + value[1] * value[1] +
            value[2] * value[2] + value[3] * value[3]);
        if (magnitude <= 1e-12)
            return [0, 0, 0, 1];
        return [value[0] / magnitude, value[1] / magnitude,
            value[2] / magnitude, value[3] / magnitude];
    }

    private static double[4] blendRotation(double[4] a, double[4] b,
        double amount)
    {
        double dotValue = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] +
            a[3] * b[3];
        const sign = dotValue < 0 ? -1.0 : 1.0;
        return normalizeRotation([
            a[0] + (b[0] * sign - a[0]) * amount,
            a[1] + (b[1] * sign - a[1]) * amount,
            a[2] + (b[2] * sign - a[2]) * amount,
            a[3] + (b[3] * sign - a[3]) * amount]);
    }

    private PoseOverride sampleLiveTrack(const LiveTrack track, double time)
    {
        PoseOverride result;
        result.node = track.node;
        if (track.keys.length == 0)
            return result;
        LiveKey first = track.keys[0];
        LiveKey second = first;
        double fraction = 0;
        if (time <= track.keys[0].time)
            first = second = track.keys[0];
        else if (time >= track.keys[$ - 1].time)
            first = second = track.keys[$ - 1];
        else
            foreach (index; 1 .. track.keys.length)
                if (time <= track.keys[index].time)
                {
                    first = track.keys[index - 1];
                    second = track.keys[index];
                    const span = second.time - first.time;
                    fraction = span <= 1e-12 ? 0 :
                        (time - first.time) / span;
                    break;
                }
        if (first.hasTranslation)
        {
            result.hasTranslation = true;
            result.translation = Vec3(
                first.translation.x + (second.translation.x -
                    first.translation.x) * fraction,
                first.translation.y + (second.translation.y -
                    first.translation.y) * fraction,
                first.translation.z + (second.translation.z -
                    first.translation.z) * fraction);
        }
        if (first.hasScale)
        {
            result.hasScale = true;
            result.scale = Vec3(
                first.scale.x + (second.scale.x - first.scale.x) * fraction,
                first.scale.y + (second.scale.y - first.scale.y) * fraction,
                first.scale.z + (second.scale.z - first.scale.z) * fraction);
        }
        if (first.hasRotation)
        {
            result.hasRotation = true;
            result.rotation = blendRotation(first.rotation, second.rotation,
                fraction);
        }
        return result;
    }

    private PoseOverride[] effectivePoseOverrides()
    {
        return effectivePoseOverridesAt(_time);
    }

    private PoseOverride[] effectivePoseOverridesAt(double time)
    {
        PoseOverride[] result = _poseOverrides.dup;
        if (_hasLiveAnimation)
            foreach (track; _liveClip.tracks)
            {
                auto sampled = sampleLiveTrack(track, time);
                sampled.additive = _liveClip.additive;
                if (sampled.hasTranslation || sampled.hasRotation ||
                    sampled.hasScale)
                    result ~= sampled;
            }
        return result;
    }

    private int collisionCountAt(double time)
    {
        const baked = bakeGltfFrame(_scene, _animation, time, true,
            effectivePoseOverridesAt(time));
        const report = findSelfIntersections(baked, 4096,
            _baselineCollisionKeys, _baselineClusters, _baselineRegions);
        return report.pairs;
    }

    private void avoidAnimationCollisions()
    {
        if (!_hasLiveAnimation)
            return;
        double[] times;
        foreach (track; _liveClip.tracks)
            foreach (key; track.keys)
            {
                bool known;
                foreach (existing; times)
                    if (abs(existing - key.time) < 1e-6)
                    {
                        known = true;
                        break;
                    }
                if (!known)
                    times ~= key.time;
            }
        times.sort();
        if (times.length > 6)
        {
            double[] reduced;
            foreach (index; 0 .. 6)
                reduced ~= times[index * (times.length - 1) / 5];
            times = reduced;
        }
        int peak;
        foreach (time; times)
            peak = max(peak, collisionCountAt(time));
        if (peak > 100)
        {
            foreach (ref track; _liveClip.tracks)
                foreach (ref key; track.keys)
                    if (key.hasRotation)
                        key.rotation = normalizeRotation([
                            key.rotation[0] * 0.65,
                            key.rotation[1] * 0.65,
                            key.rotation[2] * 0.65,
                            key.rotation[3] * 0.65 + 0.35]);
        }
    }

    private void buildCollisionBaseline()
    {
        buildCollisionBaselineAt(0.0);
    }

    private void buildCollisionBaselineAt(double time)
    {
        _baselineCollisionKeys = null;
        _baselineCollisionCount = 0;
        _baselineClusters = null;
        _baselineRegions = null;
        _baselineClusterFaces = 0;
        if (!_hasScene)
            return;
        try
        {
            Mat4[] baselineWorlds;
            const baseline = bakeGltfFrame(_scene, _animation, time, true,
                effectivePoseOverridesAt(time), &baselineWorlds);
            const report = findSelfIntersections(baseline, 100000);
            _baselineCollisionCount = report.pairs;
            foreach (key; report.keys)
                _baselineCollisionKeys[key] = true;
            if (report.pairs > 0)
            {
                // Group faces by body part, so the audit asks "did the
                // animation make two parts touch that never touch at rest"
                // instead of "did any face pair change", which a real
                // character (shoulders inside a vest) can never satisfy.
                auto parts = partPerFace(baseline);
                if (parts.length > 0)
                    _baselineClusters = parts;
                else
                    _baselineClusters = collisionClusters(
                        _baselineCollisionKeys, baseline.faces.length);
                findStrayBindings(baseline, baselineWorlds);
                auto sizes = new int[baseline.faces.length];
                foreach (cluster; _baselineClusters)
                    if (cluster >= 0 && cluster < sizes.length)
                        sizes[cluster]++;
                foreach (size; sizes)
                    _baselineClusterFaces = max(_baselineClusterFaces, size);
                // Contacts that already exist between regions are expected;
                // only new region contacts fail an animation.
                foreach (key; report.keys)
                {
                    const low = cast(int) (key >> 32);
                    const high = cast(int) (key & 0xffffffff);
                    if (low < 0 || high < 0 ||
                        low >= _baselineClusters.length ||
                        high >= _baselineClusters.length)
                        continue;
                    const firstRegion = _baselineClusters[low] <
                        _baselineClusters[high] ? _baselineClusters[low] :
                        _baselineClusters[high];
                    const secondRegion = _baselineClusters[low] <
                        _baselineClusters[high] ? _baselineClusters[high] :
                        _baselineClusters[low];
                    _baselineRegions[(cast(ulong) firstRegion << 32) |
                        cast(ulong) secondRegion] = true;
                }
                addAdjacentPartContacts();
            }
        }
        catch (Exception)
        {
        }
    }

    /**
     * A bent joint pushes its own faces into the neighbouring segment's, so a
     * parent/child part contact is articulation, not a collision. Register
     * those pairs as expected contacts.
     */
    private void addAdjacentPartContacts()
    {
        if (!_hasScene || _baselineRegions is null)
            return;
        auto partOfNode = new int[_scene.nodes.length];
        foreach (ref value; partOfNode)
            value = -1;
        foreach (skinIndex, skin; _scene.skins)
            foreach (jointIndex, node; skin.joints)
                if (node >= 0 && node < cast(int) partOfNode.length)
                    partOfNode[node] = cast(int) skinIndex * 1024 +
                        cast(int) jointIndex;
        foreach (nodeIndex, node; _scene.nodes)
        {
            if (partOfNode[nodeIndex] < 0)
                continue;
            const parent = parentNode(cast(int) nodeIndex);
            if (parent < 0 || parent >= cast(int) partOfNode.length ||
                partOfNode[parent] < 0)
                continue;
            const a = partOfNode[nodeIndex];
            const b = partOfNode[parent];
            const lower = a < b ? a : b;
            const upper = a < b ? b : a;
            _baselineRegions[(cast(ulong) lower << 32) | cast(ulong) upper] =
                true;
        }
    }

    /**
     * Parts excluded from the body audit because the clip declares them as held
     * props: a weapon in the hands overlaps the gripping arm by design.
     */
    private void buildIgnoredParts()
    {
        _scanIgnoredParts = null;
        if (!_hasScene)
            return;
        if (_baselineStrayParts !is null)
            foreach (part, stray; _baselineStrayParts)
                if (stray)
                    _scanIgnoredParts[part] = true;
        if (_scanIgnorePartNames.length == 0)
            return;
        auto ignored = new bool[_scene.nodes.length];
        void mark(int current)
        {
            if (current < 0 || current >= cast(int) ignored.length ||
                ignored[current])
                return;
            ignored[current] = true;
            foreach (child; _scene.nodes[current].children)
                mark(child);
        }
        foreach (name; _scanIgnorePartNames)
            foreach (index, node; _scene.nodes)
                if (node.name == name)
                    mark(cast(int) index);
        foreach (skinIndex, skin; _scene.skins)
            foreach (jointIndex, node; skin.joints)
                if (node >= 0 && node < cast(int) ignored.length &&
                    ignored[node])
                    _scanIgnoredParts[cast(int) skinIndex * 1024 +
                        cast(int) jointIndex] = true;
    }

    /**
     * Find faces whose dominant joint sits far from the face itself. A game
     * asset can carry stray weights that bind geometry to a distant bone; those
     * faces then sweep through the body when an unrelated bone moves, which
     * would read as an animation collision. Report and exclude them instead.
     */
    private void findStrayBindings(const Mesh mesh, const Mat4[] worlds)
    {
        _baselineStrayFaces = 0;
        _baselineStrayParts = null;
        if (worlds.length == 0 || _baselineClusters is null)
            return;
        enum double StrayDistance = 0.45;
        foreach (faceIndex, face; mesh.faces)
        {
            const part = _baselineClusters[faceIndex];
            const node = partNode(part);
            if (node < 0 || node >= cast(int) worlds.length)
                continue;
            const bone = Vec3(worlds[node].m[12], worlds[node].m[13],
                worlds[node].m[14]);
            const centroid = Vec3(
                (mesh.vertices[face.a].x + mesh.vertices[face.b].x +
                    mesh.vertices[face.c].x) / 3.0,
                (mesh.vertices[face.a].y + mesh.vertices[face.b].y +
                    mesh.vertices[face.c].y) / 3.0,
                (mesh.vertices[face.a].z + mesh.vertices[face.b].z +
                    mesh.vertices[face.c].z) / 3.0);
            const delta = Vec3(centroid.x - bone.x, centroid.y - bone.y,
                centroid.z - bone.z);
            if (sqrt(dot(delta, delta)) <= StrayDistance)
                continue;
            _baselineStrayParts[part] = true;
            _baselineStrayFaces++;
        }
    }

    private int animationTrackCount()
    {
        if (_hasLiveAnimation)
            return cast(int) _liveClip.tracks.length;
        return _hasScene ? cast(int) _scene.animations.length : 0;
    }

    /**
     * Body part id per face, from the dominant skin joint the bake recorded.
     * Faces with no binding fall back to a unique id so they keep behaving
     * like individual faces.
     */
    private static int[] partPerFace(const Mesh mesh)
    {
        int[] parts;
        if (mesh.vertexJoints.length != mesh.vertices.length ||
            mesh.vertices.length == 0)
            return parts;
        parts.length = mesh.faces.length;
        foreach (index, face; mesh.faces)
        {
            int part = -1;
            foreach (vertex; [face.a, face.b, face.c])
                if (vertex >= 0 && vertex < mesh.vertexJoints.length &&
                    mesh.vertexJoints[vertex] >= 0)
                {
                    part = mesh.vertexJoints[vertex];
                    break;
                }
            parts[index] = part >= 0 ? part : 1000000 + cast(int) index;
        }
        return parts;
    }

    /** Names of the first few new body-part contacts, for authoring feedback. */
    private string contactPartNames(const CollisionReport report)
    {
        if (_baselineRegions is null)
            return "";
        string[] names;
        foreach (key; report.keys)
        {
            if (names.length >= 4)
                break;
            names ~= format("%s/%s", partName(cast(int) (key >> 32)),
                partName(cast(int) (key & 0xffffffff)));
        }
        return names.join(",");
    }

    /** Scene node index for a part id, or -1. */
    private int partNode(int part)
    {
        if (part < 0 || part >= 1000000)
            return -1;
        const skinIndex = part / 1024;
        const jointIndex = part % 1024;
        if (!_hasScene || skinIndex >= cast(int) _scene.skins.length)
            return -1;
        const joints = _scene.skins[skinIndex].joints;
        if (jointIndex >= cast(int) joints.length)
            return -1;
        return joints[jointIndex];
    }

    private string partName(int part)
    {
        if (part >= 1000000)
            return "unbound";
        const node = partNode(part);
        if (node >= 0 && node < cast(int) _scene.nodes.length)
        {
            const name = _scene.nodes[node].name;
            if (name.length > 0)
                return name;
        }
        return format("part%d", part);
    }

    private int animationKeyCount()
    {
        if (!_hasLiveAnimation)
            return 0;
        int count;
        foreach (track; _liveClip.tracks)
            count += cast(int) track.keys.length;
        return count;
    }

    private int animationFrameCount()
    {
        const duration = _hasLiveAnimation ? _liveClip.duration :
            (_hasScene && _scene.animations.length > 0 ?
                gltfAnimationDuration(_scene, _animation) : 0);
        return duration > 0 ? cast(int) (duration * 30 + 0.5) : 0;
    }

    private void auditCurrent()
    {
        _auditNonFinite = 0;
        _auditInvalidFaces = 0;
        _auditWarnings = null;
        foreach (vertex; _mesh.vertices)
            if (!isFinite(vertex.x) || !isFinite(vertex.y) ||
                !isFinite(vertex.z))
                _auditNonFinite++;
        foreach (normal; _mesh.normals)
            if (!isFinite(normal.x) || !isFinite(normal.y) ||
                !isFinite(normal.z))
                _auditNonFinite++;
        double maximumCoordinate = 0;
        foreach (vertex; _mesh.vertices)
            maximumCoordinate = max(maximumCoordinate,
                max(abs(vertex.x), max(abs(vertex.y), abs(vertex.z))));
        foreach (face; _mesh.faces)
            if (face.a < 0 || face.b < 0 || face.c < 0 ||
                face.a >= _mesh.vertices.length ||
                face.b >= _mesh.vertices.length ||
                face.c >= _mesh.vertices.length)
                _auditInvalidFaces++;
        if (_auditNonFinite > 0)
            _auditWarnings ~= "non-finite mesh data";
        if (_auditInvalidFaces > 0)
            _auditWarnings ~= "invalid faces";
        if (maximumCoordinate > 100)
            _auditWarnings ~= "mesh bounds out of range";
        if (_hasLiveAnimation)
        {
            if (_liveClip.tracks.length == 0)
                _auditWarnings ~= "clip has no tracks";
            if (_liveClip.duration <= 0)
                _auditWarnings ~= "clip duration is zero";
            foreach (track; _liveClip.tracks)
            {
                if (track.keys.length == 0)
                    _auditWarnings ~= "empty track";
                foreach (index, key; track.keys)
                {
                    if (key.time < 0 || key.time > _liveClip.duration)
                        _auditWarnings ~= "key outside duration";
                    if (index > 0 && key.time < track.keys[index - 1].time)
                        _auditWarnings ~= "unsorted keys";
                }
            }
        }
        _auditValid = _auditNonFinite == 0 &&
            _auditInvalidFaces == 0 && _auditWarnings.length == 0;
    }

    private void writeAuditReport()
    {
        try
            writeReport("build/live-audit.json", format(
                `{"frame":%d,"frames":%d,"time":%.4f,"clip":"%s","tracks":%d,"keys":%d,"valid":%s,"nonFinite":%d,"invalidFaces":%d,"warnings":"%s"}`,
                cast(int) (_time * 30 + 0.5), animationFrameCount(), _time,
                jsonEscape(_hasLiveAnimation ? _liveClip.name : ""),
                animationTrackCount(), animationKeyCount(),
                _auditValid ? "true" : "false", _auditNonFinite,
                _auditInvalidFaces,
                jsonEscape(_auditWarnings.join("|"))));
        catch (Exception)
        {
        }
    }

    /** Escape a value for a JSON string literal. */
    private static string jsonEscape(string value)
    {
        string result;
        foreach (character; value)
        {
            switch (character)
            {
                case '"':
                    result ~= `\"`;
                    break;
                case '\\':
                    result ~= `\\`;
                    break;
                case '\n':
                    result ~= `\n`;
                    break;
                case '\r':
                    result ~= `\r`;
                    break;
                case '\t':
                    result ~= `\t`;
                    break;
                default:
                    result ~= character;
            }
        }
        return result;
    }

    /**
     * Replace a report file in one step. The UI and driver threads both refresh
     * these files, and a half written file is not parseable by the tools that
     * poll them.
     */
    private static void writeReport(string path, string text)
    {
        const temporary = path ~ ".tmp";
        write(temporary, text);
        if (exists(path))
            stdRemove(path);
        rename(temporary, path);
    }

    private void scanAnimationFrames()
    {
        _scanRequested = false;
        _scanFrameCount = max(1, animationFrameCount());
        _scanInvalidFrames = 0;
        _scanLimbHits = 0;
        _scanCollisionFrames = 0;
        _scanCollisionPairs = 0;
        _scanRestoreTime = _time;
        buildCollisionBaselineAt(_time);
        _scanLeftHand = liveNodeIndex("LeftHand");
        _scanRightHand = liveNodeIndex("RightHand");
        _scanLeftForeArm = liveNodeIndex("LeftForeArm");
        _scanRightForeArm = liveNodeIndex("RightForeArm");
        _scanHips = liveNodeIndex("Hips");
        _scanNeck = liveNodeIndex("Neck");
        _scanHead = liveNodeIndex("Head");
        buildIgnoredParts();
        _scanPreviousLeft = Vec3(0, 0, 0);
        _scanPreviousRight = Vec3(0, 0, 0);
        _scanHavePrevious = false;
        _scanReport = `{"frames":[`;
        _scanCursor = 0;
        if (_scanIncremental)
        {
            _scanRunning = true;
            _status = format("Scanning frame 0/%d", _scanFrameCount);
            return;
        }
        while (_scanCursor < _scanFrameCount)
            processScanFrame();
        finishFrameScan();
    }

    private void processScanFrame()
    {
        const frame = _scanCursor;
        _time = cast(double) frame / 30.0;
        rebuildGltfMesh();
        auditCurrent();
        double maximumCoordinate = 0;
        foreach (vertex; _mesh.vertices)
            maximumCoordinate = max(maximumCoordinate,
                max(abs(vertex.x), max(abs(vertex.y), abs(vertex.z))));
        Vec3 left = Vec3(0, 0, 0);
        Vec3 right = Vec3(0, 0, 0);
        if (_scanLeftHand >= 0 && _scanLeftHand < _nodeWorlds.length)
            left = Vec3(_nodeWorlds[_scanLeftHand].m[12],
                _nodeWorlds[_scanLeftHand].m[13],
                _nodeWorlds[_scanLeftHand].m[14]);
        if (_scanRightHand >= 0 && _scanRightHand < _nodeWorlds.length)
            right = Vec3(_nodeWorlds[_scanRightHand].m[12],
                _nodeWorlds[_scanRightHand].m[13],
                _nodeWorlds[_scanRightHand].m[14]);
        int limbHits;
        if (_scanHips >= 0 && _scanHips < _nodeWorlds.length &&
            _scanNeck >= 0 && _scanNeck < _nodeWorlds.length)
        {
            const hipsPosition = Vec3(_nodeWorlds[_scanHips].m[12],
                _nodeWorlds[_scanHips].m[13], _nodeWorlds[_scanHips].m[14]);
            const neckPosition = Vec3(_nodeWorlds[_scanNeck].m[12],
                _nodeWorlds[_scanNeck].m[13], _nodeWorlds[_scanNeck].m[14]);
            foreach (node; [_scanLeftHand, _scanRightHand,
                _scanLeftForeArm, _scanRightForeArm])
                if (node >= 0 && node < _nodeWorlds.length)
                {
                    const position = Vec3(_nodeWorlds[node].m[12],
                        _nodeWorlds[node].m[13], _nodeWorlds[node].m[14]);
                    if (pointSegmentDistance(position, hipsPosition,
                        neckPosition) < 0.10)
                        limbHits++;
                }
        }
        if (_scanHead >= 0 && _scanHead < _nodeWorlds.length)
        {
            // A wave brings a hand toward the face, so audit the head too.
            const headMatrix = _nodeWorlds[_scanHead];
            const headBase = Vec3(headMatrix.m[12], headMatrix.m[13],
                headMatrix.m[14]);
            const headUp = normalize(Vec3(headMatrix.m[4], headMatrix.m[5],
                headMatrix.m[6]));
            const headTip = meshAdd(headBase, meshScale(headUp, 0.16));
            foreach (node; [_scanLeftHand, _scanRightHand])
                if (node >= 0 && node < _nodeWorlds.length)
                {
                    const position = Vec3(_nodeWorlds[node].m[12],
                        _nodeWorlds[node].m[13], _nodeWorlds[node].m[14]);
                    if (pointSegmentDistance(position, headBase, headTip) < 0.10)
                        limbHits++;
                }
        }
        _scanLimbHits += limbHits;
        double jump = 0;
        if (_scanHavePrevious && _scanLeftHand >= 0 && _scanRightHand >= 0 &&
            isFinite(left.x) && isFinite(left.y) && isFinite(left.z) &&
            isFinite(right.x) && isFinite(right.y) && isFinite(right.z))
        {
            jump = max(
                sqrt((left.x - _scanPreviousLeft.x) *
                    (left.x - _scanPreviousLeft.x) +
                    (left.y - _scanPreviousLeft.y) *
                    (left.y - _scanPreviousLeft.y) +
                    (left.z - _scanPreviousLeft.z) *
                    (left.z - _scanPreviousLeft.z)),
                sqrt((right.x - _scanPreviousRight.x) *
                    (right.x - _scanPreviousRight.x) +
                    (right.y - _scanPreviousRight.y) *
                    (right.y - _scanPreviousRight.y) +
                    (right.z - _scanPreviousRight.z) *
                    (right.z - _scanPreviousRight.z)));
        }
        _scanPreviousLeft = left;
        _scanPreviousRight = right;
        _scanHavePrevious = true;
        if (maximumCoordinate > 100)
        {
            _auditWarnings ~= "mesh bounds out of range";
            _auditValid = false;
        }
        if (jump > 0.35)
        {
            _auditWarnings ~= "hand jump";
            _auditValid = false;
        }
        if (limbHits > 0)
        {
            _auditWarnings ~= "limb/torso overlap";
            _auditValid = false;
        }
        int collisions;
        string contactParts;
        if (_scanCollisions)
        {
            const collisionReport = findSelfIntersections(_mesh, 64,
                _baselineCollisionKeys, _baselineClusters, _baselineRegions,
                _scanIgnoredParts);
            collisions = collisionReport.pairs;
            contactParts = contactPartNames(collisionReport);
            _scanCollisionPairs += collisions;
            if (collisions > 0)
            {
                _scanCollisionFrames++;
                _auditWarnings ~= "mesh collision";
                _auditValid = false;
            }
        }
        if (!_auditValid)
            _scanInvalidFrames++;
        if (frame > 0)
            _scanReport ~= ",";
        _scanReport ~= format(
            `{"frame":%d,"time":%.4f,"valid":%s,"nonFinite":%d,"invalidFaces":%d,"jump":%.4f,"limbHits":%d,"collisions":%d,"parts":"%s","boundsValid":%s,"warnings":"%s"}`,
            frame, _time, _auditValid ? "true" : "false",
            _auditNonFinite, _auditInvalidFaces,
            jump, limbHits, collisions, jsonEscape(contactParts),
            maximumCoordinate <= 100 ? "true" : "false",
            _auditWarnings.join("|"));
        _scanCursor++;
        if (_scanIncremental && _scanCursor < _scanFrameCount)
            _status = format("Scanning frame %d/%d", _scanCursor,
                _scanFrameCount);
    }

    private void finishFrameScan()
    {
        _scanRunning = false;
        _scanReport ~= format(`],"invalidFrames":%d}`, _scanInvalidFrames);
        try
            writeReport("build/live-frames.json", _scanReport);
        catch (Exception)
        {
        }
        _time = _scanRestoreTime;
        rebuildGltfMesh();
        auditCurrent();
        _status = format("Frame scan: %d frame(s), %d invalid",
            _scanFrameCount, _scanInvalidFrames);
    }

    private void advanceFrameScan()
    {
        _scanAdvanceCount++;
        if (!_scanRunning)
            return;
        if (_scanCancelRequested)
        {
            _scanCancelRequested = false;
            _scanRunning = false;
            _time = _scanRestoreTime;
            rebuildGltfMesh();
            auditCurrent();
            _status = "Frame scan cancelled";
            return;
        }
        processScanFrame();
        if (_scanCursor >= _scanFrameCount)
            finishFrameScan();
    }

    private void writeBoneInfo()
    {
        if (_inspectNode < 0 || _inspectNode >= _nodeWorlds.length)
            return;
        const matrix = _nodeWorlds[_inspectNode];
        const position = Vec3(matrix.m[12], matrix.m[13], matrix.m[14]);
        const axisX = gltfTransformNormal(matrix, Vec3(1, 0, 0));
        const axisY = gltfTransformNormal(matrix, Vec3(0, 1, 0));
        const axisZ = gltfTransformNormal(matrix, Vec3(0, 0, 1));
        const name = _scene.nodes[_inspectNode].name;
        try
            writeReport("build/bone-info.json", format(
                `{"node":"%s","position":[%.5f,%.5f,%.5f],"axes":{"x":[%.5f,%.5f,%.5f],"y":[%.5f,%.5f,%.5f],"z":[%.5f,%.5f,%.5f]}}`,
                jsonEscape(name), position.x, position.y, position.z,
                axisX.x, axisX.y, axisX.z,
                axisY.x, axisY.y, axisY.z,
                axisZ.x, axisZ.y, axisZ.z));
        catch (Exception)
        {
        }
        _status = "Bone axes: " ~ name ~ " · build/bone-info.json";
        _inspectNode = -1;
    }

    /**
     * Write the rig inventory authors need: every node with its hierarchy,
     * deform-joint flag, and world position/axes at the current pose.
     */
    private void writeBoneList()
    {
        if (!_hasScene)
            return;
        auto joint = new bool[_scene.nodes.length];
        foreach (skin; _scene.skins)
            foreach (candidate; skin.joints)
                if (candidate >= 0 && candidate < joint.length)
                    joint[candidate] = true;
        string[] entries;
        foreach (index, node; _scene.nodes)
        {
            const matrix = index < _nodeWorlds.length ?
                _nodeWorlds[index] : Mat4.identity();
            const position = Vec3(matrix.m[12], matrix.m[13], matrix.m[14]);
            const axisX = normalize(gltfTransformNormal(matrix,
                Vec3(1, 0, 0)));
            const axisY = normalize(gltfTransformNormal(matrix,
                Vec3(0, 1, 0)));
            const axisZ = normalize(gltfTransformNormal(matrix,
                Vec3(0, 0, 1)));
            const parent = parentNode(cast(int) index);
            entries ~= format(
                `{"index":%d,"name":"%s","parent":%d,"parentName":"%s","children":%d,"joint":%s,"position":[%.4f,%.4f,%.4f],"axes":{"x":[%.4f,%.4f,%.4f],"y":[%.4f,%.4f,%.4f],"z":[%.4f,%.4f,%.4f]}}`,
                index, jsonEscape(node.name), parent,
                parent >= 0 ? jsonEscape(_scene.nodes[parent].name) : "",
                node.children.length, joint[index] ? "true" : "false",
                position.x, position.y, position.z,
                axisX.x, axisX.y, axisX.z,
                axisY.x, axisY.y, axisY.z,
                axisZ.x, axisZ.y, axisZ.z);
        }
        try
        {
            writeReport("build/bones.json",
                format(`{"nodes":[%s]}`, entries.join(",")));
            _status = format("Bone list: %d nodes · build/bones.json",
                _scene.nodes.length);
        }
        catch (Exception)
        {
        }
    }

    /** Base (un-posed) node world matrices used to resolve world axes. */
    private Mat4[] baseWorldMatrices()
    {
        Mat4[] worlds;
        if (!_hasScene)
            return worlds;
        try
            bakeGltfFrame(_scene, _animation, 0.0, false, null, &worlds);
        catch (Exception)
        {
        }
        return worlds;
    }

    /** Rotate a world axis into the node's local frame so a key spins it. */
    private static Vec3 worldAxisToLocal(const Mat4[] worlds, int node,
        Vec3 axis)
    {
        if (node < 0 || node >= worlds.length)
            return Vec3(0, 0, 0);
        const matrix = worlds[node];
        const basisX = normalize(Vec3(matrix.m[0], matrix.m[1], matrix.m[2]));
        const basisY = normalize(Vec3(matrix.m[4], matrix.m[5], matrix.m[6]));
        const basisZ = normalize(Vec3(matrix.m[8], matrix.m[9], matrix.m[10]));
        return Vec3(dot(basisX, axis), dot(basisY, axis), dot(basisZ, axis));
    }

    private static double[4] axisAngleRotation(Vec3 axis, double degrees)
    {
        const unit = normalize(axis);
        const half = degrees * 3.141592653589793 / 360.0;
        const sine = sin(half);
        return [unit.x * sine, unit.y * sine, unit.z * sine, cos(half)];
    }

    /** Rodrigues rotation of a vector around a world axis, in degrees. */
    private static Vec3 rotateAroundAxis(Vec3 axis, double degrees, Vec3 value)
    {
        const unit = normalize(axis);
        const angle = degrees * 3.141592653589793 / 180.0;
        const cosine = cos(angle);
        const sine = sin(angle);
        return meshAdd(
            meshAdd(meshScale(value, cosine),
                meshScale(meshCross(unit, value), sine)),
            meshScale(unit, dot(unit, value) * (1 - cosine)));
    }

    /** Convert a world position into a node's parent space. */
    private static Vec3 parentSpacePosition(const Mat4[] worlds, int parent,
        Vec3 world)
    {
        if (parent < 0 || parent >= worlds.length)
            return world;
        const matrix = worlds[parent];
        const origin = Vec3(matrix.m[12], matrix.m[13], matrix.m[14]);
        const delta = Vec3(world.x - origin.x, world.y - origin.y,
            world.z - origin.z);
        const basisX = normalize(Vec3(matrix.m[0], matrix.m[1], matrix.m[2]));
        const basisY = normalize(Vec3(matrix.m[4], matrix.m[5], matrix.m[6]));
        const basisZ = normalize(Vec3(matrix.m[8], matrix.m[9], matrix.m[10]));
        return Vec3(dot(basisX, delta), dot(basisY, delta),
            dot(basisZ, delta));
    }

    /**
     * Quaternion that spins a node by `degrees` around a world axis, keeping its
     * rest orientation. A replace-mode override supplies the whole local
     * rotation, so it composes the parent-frame axis with the node's base local
     * rotation; an additive override only supplies the delta.
     */
    private double[4] worldAxisKeyRotation(const Mat4[] worlds, int node,
        Vec3 worldAxis, double degrees, bool additive)
    {
        if (node < 0 || node >= worlds.length)
            return [0.0, 0.0, 0.0, 1.0];
        const parent = parentNode(node);
        const frame = additive ? node : (parent >= 0 ? parent : node);
        const spin = axisAngleRotation(worldAxisToLocal(worlds, frame,
            worldAxis), degrees);
        if (additive)
            return spin;
        const parentRotation = parent >= 0 && parent < worlds.length ?
            quatEditorFromMatrix(worlds[parent]) : [0.0, 0.0, 0.0, 1.0];
        const localRotation = quatEditorMultiply(
            quatEditorConjugate(parentRotation),
            quatEditorFromMatrix(worlds[node]));
        return quatEditorMultiply(spin, localRotation);
    }

    /** A world axis given as "x"/"y"/"z" or as a three number array. */
    private static Vec3 liveAxisValue(JSONValue value)
    {
        if (value.type == JSONType.string)
        {
            if (value.str == "y")
                return Vec3(0, 1, 0);
            if (value.str == "z")
                return Vec3(0, 0, 1);
            return Vec3(1, 0, 0);
        }
        const numbers = liveNumbers(value);
        if (numbers.length >= 3)
            return Vec3(numbers[0], numbers[1], numbers[2]);
        return Vec3(0, 0, 0);
    }

    private double pointSegmentDistance(Vec3 point, Vec3 start, Vec3 end)
    {
        const abx = end.x - start.x;
        const aby = end.y - start.y;
        const abz = end.z - start.z;
        const lengthSquared = abx * abx + aby * aby + abz * abz;
        double t = lengthSquared > 1e-12 ?
            ((point.x - start.x) * abx + (point.y - start.y) * aby +
                (point.z - start.z) * abz) / lengthSquared : 0;
        t = min(1.0, max(0.0, t));
        const dx = point.x - (start.x + abx * t);
        const dy = point.y - (start.y + aby * t);
        const dz = point.z - (start.z + abz * t);
        return sqrt(dx * dx + dy * dy + dz * dz);
    }

    private int liveNodeIndex(string name)
    {
        foreach (index, node; _scene.nodes)
            if (node.name == name)
                return cast(int) index;
        try
            return to!int(name);
        catch (Exception)
            return -1;
    }

    private int parentNode(int childIndex)
    {
        foreach (index, node; _scene.nodes)
            foreach (candidate; node.children)
                if (candidate == childIndex)
                    return cast(int) index;
        return -1;
    }

    private double[4] quatEditorMultiply(double[4] a, double[4] b)
    {
        const result = [
            a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
            a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
            a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
            a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
        const length = sqrt(result[0] * result[0] + result[1] * result[1] +
            result[2] * result[2] + result[3] * result[3]);
        return length > 1e-12 ?
            [result[0] / length, result[1] / length,
                result[2] / length, result[3] / length] :
            [0.0, 0.0, 0.0, 1.0];
    }

    private double[4] quatEditorConjugate(double[4] q)
    {
        return [-q[0], -q[1], -q[2], q[3]];
    }

    private double[4] quatEditorFromMatrix(Mat4 matrix)
    {
        double xx = matrix.m[0], xy = matrix.m[4], xz = matrix.m[8];
        double yx = matrix.m[1], yy = matrix.m[5], yz = matrix.m[9];
        double zx = matrix.m[2], zy = matrix.m[6], zz = matrix.m[10];
        const xLength = sqrt(xx * xx + yx * yx + zx * zx);
        const yLength = sqrt(xy * xy + yy * yy + zy * zy);
        const zLength = sqrt(xz * xz + yz * yz + zz * zz);
        if (xLength > 1e-12)
        {
            xx /= xLength; yx /= xLength; zx /= xLength;
        }
        if (yLength > 1e-12)
        {
            xy /= yLength; yy /= yLength; zy /= yLength;
        }
        if (zLength > 1e-12)
        {
            xz /= zLength; yz /= zLength; zz /= zLength;
        }
        const trace = xx + yy + zz;
        double[4] result;
        if (trace > 0)
        {
            const s = sqrt(trace + 1.0) * 2;
            result = [(zy - yz) / s, (xz - zx) / s,
                (yx - xy) / s, 0.25 * s];
        }
        else if (xx > yy && xx > zz)
        {
            const s = sqrt(1.0 + xx - yy - zz) * 2;
            result = [0.25 * s, (xy + yx) / s,
                (xz + zx) / s, (zy - yz) / s];
        }
        else if (yy > zz)
        {
            const s = sqrt(1.0 + yy - xx - zz) * 2;
            result = [(xy + yx) / s, 0.25 * s,
                (yz + zy) / s, (xz - zx) / s];
        }
        else
        {
            const s = sqrt(1.0 + zz - xx - yy) * 2;
            result = [(xz + zx) / s, (yz + zy) / s,
                0.25 * s, (yx - xy) / s];
        }
        const length = sqrt(result[0] * result[0] + result[1] * result[1] +
            result[2] * result[2] + result[3] * result[3]);
        return length > 1e-12 ?
            [result[0] / length, result[1] / length,
                result[2] / length, result[3] / length] :
            [0.0, 0.0, 0.0, 1.0];
    }

    private bool applyPoseAim(JSONValue command)
    {
        const name = liveString(liveChild(command, "node"));
        const childName = liveString(liveChild(command, "child"));
        const target = liveNumbers(liveChild(command, "target"));
        const node = liveNodeIndex(name);
        const child = liveNodeIndex(childName);
        if (node < 0 || child < 0 || target.length < 3 ||
            node >= _nodeWorlds.length || child >= _nodeWorlds.length)
            return false;
        const originMatrix = _nodeWorlds[node];
        const childMatrix = _nodeWorlds[child];
        const origin = Vec3(originMatrix.m[12], originMatrix.m[13],
            originMatrix.m[14]);
        const currentDirection = Vec3(childMatrix.m[12] - origin.x,
            childMatrix.m[13] - origin.y, childMatrix.m[14] - origin.z);
        const desiredDirection = Vec3(target[0] - origin.x,
            target[1] - origin.y, target[2] - origin.z);
        const currentLength = sqrt(currentDirection.x * currentDirection.x +
            currentDirection.y * currentDirection.y +
            currentDirection.z * currentDirection.z);
        const desiredLength = sqrt(desiredDirection.x * desiredDirection.x +
            desiredDirection.y * desiredDirection.y +
            desiredDirection.z * desiredDirection.z);
        if (currentLength < 1e-9 || desiredLength < 1e-9)
            return false;
        const a = Vec3(currentDirection.x / currentLength,
            currentDirection.y / currentLength,
            currentDirection.z / currentLength);
        const b = Vec3(desiredDirection.x / desiredLength,
            desiredDirection.y / desiredLength,
            desiredDirection.z / desiredLength);
        const cross = Vec3(a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
        const worldRotation = quatEditorMultiply([cross.x, cross.y, cross.z,
            1.0 + a.x * b.x + a.y * b.y + a.z * b.z], [0, 0, 0, 1]);
        const parent = parentNode(node);
        const parentRotation = parent >= 0 && parent < _nodeWorlds.length ?
            quatEditorFromMatrix(_nodeWorlds[parent]) : [0.0, 0.0, 0.0, 1.0];
        const localRotation = quatEditorMultiply(
            quatEditorMultiply(quatEditorConjugate(parentRotation),
                worldRotation), parentRotation);
        PoseOverride overrideValue;
        overrideValue.node = node;
        overrideValue.hasRotation = true;
        overrideValue.rotation = localRotation;
        overrideValue.preAdditive = true;
        _poseOverrides ~= overrideValue;
        return true;
    }

    private bool applyLiveKeyframe(JSONValue command, bool remove)
    {
        const nodeName = liveString(liveChild(command, "node"));
        int node = liveNodeIndex(nodeName);
        if (node < 0 && liveHas(command, "node"))
            node = cast(int) liveInteger(liveChild(command, "node"));
        if (node < 0 || node >= _scene.nodes.length)
            return false;
        const time = liveHas(command, "time") ?
            liveNumber(liveChild(command, "time")) : _time;
        if (!_hasLiveAnimation)
        {
            if (remove)
                return false;
            _liveClip = LiveClip();
            _liveClip.name = "LiveEdit";
            _liveClip.duration = 2.0;
            _liveClip.loop = true;
            _liveClip.additive = true;
            _hasLiveAnimation = true;
        }
        int trackIndex = -1;
        foreach (index, track; _liveClip.tracks)
            if (track.node == node)
            {
                trackIndex = cast(int) index;
                break;
            }
        if (remove)
        {
            if (trackIndex < 0)
                return false;
            auto keys = _liveClip.tracks[trackIndex].keys;
            keys = keys.filter!(key => abs(key.time - time) >= 1e-6).array;
            _liveClip.tracks[trackIndex].keys = keys;
            if (keys.length == 0)
                _liveClip.tracks = _liveClip.tracks[0 .. trackIndex] ~
                    _liveClip.tracks[trackIndex + 1 .. $];
            _playing = false;
            return true;
        }
        if (trackIndex < 0)
        {
            LiveTrack track;
            track.node = node;
            _liveClip.tracks ~= track;
            trackIndex = cast(int) _liveClip.tracks.length - 1;
        }
        LiveKey key;
        key.time = time;
        const translation = liveNumbers(liveChild(command, "translation"));
        if (translation.length >= 3)
        {
            key.hasTranslation = true;
            key.translation = Vec3(translation[0], translation[1],
                translation[2]);
        }
        const rotation = liveNumbers(liveChild(command, "rotation"));
        if (rotation.length >= 4)
        {
            key.hasRotation = true;
            key.rotation = [rotation[0], rotation[1], rotation[2],
                rotation[3]];
        }
        const scale = liveNumbers(liveChild(command, "scale"));
        if (scale.length >= 3)
        {
            key.hasScale = true;
            key.scale = Vec3(scale[0], scale[1], scale[2]);
        }
        if (!key.hasTranslation && !key.hasRotation && !key.hasScale)
            return false;
        bool replaced;
        foreach (ref existing; _liveClip.tracks[trackIndex].keys)
            if (abs(existing.time - time) < 1e-6)
            {
                existing = key;
                replaced = true;
                break;
            }
        if (!replaced)
            _liveClip.tracks[trackIndex].keys ~= key;
        _liveClip.tracks[trackIndex].keys.sort!((a, b) => a.time < b.time);
        double maximumTime;
        foreach (track; _liveClip.tracks)
            foreach (existing; track.keys)
                maximumTime = max(maximumTime, existing.time);
        if (_liveClip.duration < maximumTime)
            _liveClip.duration = maximumTime;
        _playing = false;
        return true;
    }

    private void captureViewport(string path)
    {
        const width = max(1, bounds().width - SidebarWidth);
        const height = max(1, bounds().height);
        RenderOptions options;
        options.wireframe = _wireframe;
        options.vertices = _wireframe;
        options.cullBackfaces = _cull;
        options.selectedVertex = _selected;
        const frame = renderMesh(_mesh, _camera, width, height, options);
        writePpm(path, frame);
        _lastCapturePath = path;
        _status = "Captured " ~ path;
    }

    private void writeAnimationSheet(string path)
    {
        const frames = max(1, animationFrameCount());
        const columns = min(5, frames);
        const rows = (frames + columns - 1) / columns;
        const tileWidth = 220;
        const tileHeight = 220;
        const originalTime = _time;
        RenderOptions options;
        options.wireframe = _wireframe;
        options.vertices = _wireframe;
        options.cullBackfaces = _cull;
        RgbFrame[] tiles;
        foreach (frame; 0 .. frames)
        {
            _time = cast(double) frame / 30.0;
            rebuildGltfMesh();
            tiles ~= renderMesh(_mesh, _camera, tileWidth, tileHeight,
                options);
        }
        _time = originalTime;
        rebuildGltfMesh();
        auditCurrent();
        RgbFrame sheet;
        sheet.width = columns * tileWidth;
        sheet.height = rows * tileHeight;
        sheet.pixels = new ubyte[sheet.width * sheet.height * 3];
        foreach (frame, tile; tiles)
        {
            const column = frame % columns;
            const row = frame / columns;
            foreach (y; 0 .. tileHeight)
                foreach (x; 0 .. tileWidth)
                {
                    const source = (y * tileWidth + x) * 3;
                    const target = ((row * tileHeight + y) * sheet.width +
                        column * tileWidth + x) * 3;
                    sheet.pixels[target] = tile.pixels[source];
                    sheet.pixels[target + 1] = tile.pixels[source + 1];
                    sheet.pixels[target + 2] = tile.pixels[source + 2];
                }
        }
        writePpm(path, sheet);
        _lastSheetPath = path;
        _status = format("Animation sheet: %d frames -> %s", frames, path);
    }

    void setLivePath(string path)
    {
        _livePath = path;
    }

    void setRendererInfo(string name, bool hardware, string fallback)
    {
        _rendererName = name;
        _rendererHardware = hardware;
        _rendererFallback = fallback;
    }

    void writeDriverState(string path)
    {
        try
            write(path, format(
                `{"time":%.4f,"frame":%d,"ticks":%d,"advances":%d,"scanRunning":%s,"scanFrame":%d,"scanTotal":%d,"invalidFrames":%d,"collisionFrames":%d,"collisionPairs":%d}`,
                _time, cast(int) (_time * 30 + 0.5), _scanTickCount,
                _scanAdvanceCount,
                _scanRunning ? "true" : "false", _scanCursor,
                _scanFrameCount, _scanInvalidFrames, _scanCollisionFrames,
                _scanCollisionPairs));
        catch (Exception)
        {
        }
    }

    void tickLive()
    {
        synchronized (_liveMutex)
            tickLiveLocked();
    }

    private void tickLiveLocked()
    {
        _scanTickCount++;
        if (!_hasScene || _livePath.length == 0 || !exists(_livePath))
            return;
        string text;
        try
            text = readText(_livePath);
        catch (Exception)
            return;
        if (text == _liveText)
        {
            advanceFrameScan();
            writeAuditReport();
            writeLiveAck();
            return;
        }
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
        if (_checkCollisions)
        {
            buildCollisionBaselineAt(_time);
            _collisions = findSelfIntersections(_mesh, 4096,
                _baselineCollisionKeys, _baselineClusters, _baselineRegions,
                _scanIgnoredParts);
            _checkCollisions = false;
            _status = format(
                "Live: %d object(s), %d pose override(s) · %d collisions",
                _liveExtras.length, _poseOverrides.length, _collisions.pairs);
        }
        if (_collisions.faceA < 0)
            _collisions.sample = Vec3(0, 0, 0);
        auditCurrent();
        writeAuditReport();
        if (_inspectNode >= 0)
            writeBoneInfo();
        if (_listBones)
        {
            writeBoneList();
            _listBones = false;
        }
        if (_scanRequested)
            scanAnimationFrames();
        if (_capturePath.length > 0)
        {
            try
                captureViewport(_capturePath);
            catch (Exception)
            {
            }
            _capturePath.length = 0;
        }
        if (_sheetPath.length > 0)
        {
            try
                writeAnimationSheet(_sheetPath);
            catch (Exception)
            {
            }
            _sheetPath.length = 0;
        }
        if (_pendingSavePath.length > 0)
        {
            try
                write(_pendingSavePath, toGlb(_mesh));
            catch (Exception)
            {
            }
            _pendingSavePath.length = 0;
        }
        _liveStatus = "Live revision " ~ to!string(revision);
        writeLiveAck();
        invalidate();
    }

    // Region edits are state, not a one-off operation: the mesh is rebaked for
    // every animation frame, so each edit is replayed onto the fresh mesh.
    private RegionEdit[] _reshapecs;
    private string _lastReshape;
    private int _lastReshaped;
    private double _lastReshapeMs = 0.0; // D floats default to NaN
    private int _reshapeRuns;


    /**
     * Replay recorded region edits onto the current mesh.
     *
     * Only the vertices inside a region move, which is what keeps a replay cheap
     * enough to sit inside a frame instead of a reload.
     */
    private void applyReshapes()
    {
        if (_reshapecs.length == 0 || _mesh.vertices.length == 0)
            return;
        const start = MonoTime.currTime();
        const beforeIndices = regionVertices(_mesh, regionBox("feet"));
        const beforeFeet = beforeIndices.length;
        ++_reshapeRuns;
        double lowY = double.max;
        double highY = -double.max;
        foreach (vertex; _mesh.vertices)
        {
            lowY = vertex.y < lowY ? vertex.y : lowY;
            highY = vertex.y > highY ? vertex.y : highY;
        }
        int moved;
        foreach (edit; _reshapecs)
            moved += edit.hasBox ?
                reshapeBox(_mesh, edit.box, edit.region, edit.style,
                    edit.strength) :
                reshapeRegion(_mesh, edit.region, edit.style, edit.strength);
        _lastReshaped = moved;
        _lastReshapeMs = (MonoTime.currTime() - start).total!"usecs" / 1000.0;
        // A reshaped region that draws dark usually means the per-face material
        // table no longer lines up with the faces, so record both.
        int downward;
        int zeroLength;
        double meanUp;
        const feet = regionVertices(_mesh, regionBox("feet"));
        foreach (index; feet)
        {
            if (index < 0 || index >= _mesh.normals.length)
                continue;
            const normal = _mesh.normals[index];
            const size = length(normal);
            if (size < 1.0e-9)
                ++zeroLength;
            meanUp += normal.y;
            if (normal.y < -0.2)
                ++downward;
        }
        double regionLowY = double.max;
        double regionHighY = -double.max;
        double regionWideX = 0.0;
        foreach (index; beforeIndices)
        {
            if (index < 0 || index >= _mesh.vertices.length)
                continue;
            const vertex = _mesh.vertices[index];
            regionLowY = vertex.y < regionLowY ? vertex.y : regionLowY;
            regionHighY = vertex.y > regionHighY ? vertex.y : regionHighY;
            const wideX = vertex.x < 0 ? -vertex.x : vertex.x;
            regionWideX = wideX > regionWideX ? wideX : regionWideX;
        }
        if (feet.length > 0)
            meanUp /= feet.length;
        try
            write("build/reshape-stats.json", format(
                `{"faces":%d,"faceMaterials":%d,"materials":%d,"vertices":%d,"skin":%.3f,%.3f,%.3f,"feet":%d,"downward":%d,"zeroLength":%d,"meanUp":%.3f,"beforeFeet":%d,"lowY":%.4f,"highY":%.4f,"runs":%d,"regionLowY":%.4f,"regionHighY":%.4f,"regionWideX":%.4f}`,
                _mesh.faces.length, _mesh.faceMaterials.length,
                _mesh.materials.length, _mesh.vertices.length,
                _mesh.materials.length > 0 ? _mesh.materials[0].baseColor.x : -1.0,
                _mesh.materials.length > 0 ? _mesh.materials[0].baseColor.y : -1.0,
                _mesh.materials.length > 0 ? _mesh.materials[0].baseColor.z : -1.0,
                feet.length, downward, zeroLength, meanUp, beforeFeet, lowY,
                highY, _reshapeRuns, regionLowY, regionHighY, regionWideX));
        catch (Exception)
        {
        }
    }

    // ---- Region editing ----------------------------------------------------
    private RegionVolume[string] _regions;
    private string _activeRegion;
    private int _maskVertices;
    private int _maskFaces;
    private string _lastOp;
    private double _lastOpMs = 0.0; // D floats default to NaN
    private bool _lastReplaceOk = true;
    private string _lastReplaceReason = "";
    private Vec3 _shellLo = Vec3(0, 0, 0);
    private Vec3 _shellHi = Vec3(0, 0, 0);
    private int _shellFaces;
    // Replacements are state, not a one-off: the mesh is rebaked for every frame,
    // so each accepted replacement is replayed onto the fresh mesh.
    private JSONValue[] _replaceCommands;

    private RegionVolume* activeRegion()
    {
        if (_activeRegion.length == 0)
            return null;
        return _activeRegion in _regions;
    }

    /// Recount what the active region covers, for the ack and the status line.
    private void refreshMaskStats()
    {
        _maskVertices = 0;
        _maskFaces = 0;
        auto region = activeRegion();
        if (region is null || _mesh.vertices.length == 0)
            return;
        const selection = selectRegion(_mesh, *region);
        _maskVertices = selection.count();
        _maskFaces = cast(int) selection.faces.length;
    }

    /**
     * Tint the faces inside the active region.
     *
     * The volume outline shows where the region is, but only the surface tint shows
     * what will actually move: a box around a leg also contains the air behind it.
     */
    private void tintSelection()
    {
        auto region = activeRegion();
        if (region is null || _mesh.faces.length == 0)
            return;
        if (_mesh.faceMaterials.length != _mesh.faces.length)
            return;
        int highlight = -1;
        foreach (index, slot; _mesh.materials)
            if (slot.baseColor.x > 0.18 && slot.baseColor.x < 0.22 &&
                slot.baseColor.y > 0.83 && slot.baseColor.z > 0.68)
                highlight = cast(int) index;
        if (highlight < 0)
        {
            MaterialSlot slot;
            slot.baseColor = Vec3(0.20, 0.85, 0.70);
            highlight = cast(int) _mesh.materials.length;
            _mesh.materials ~= slot;
        }
        foreach (index, face; _mesh.faces)
        {
            const middle = meshScale(meshAdd(meshAdd(_mesh.vertices[face.a],
                _mesh.vertices[face.b]), _mesh.vertices[face.c]), 1.0 / 3.0);
            if (regionMask(*region, middle) > 0.5)
                _mesh.faceMaterials[index] = highlight;
        }
    }

    /// Read SDF shapes from a live command array.
    private void readSdfShapes(JSONValue array, ref SdfShape[] into)
    {
        if (array.type != JSONType.array)
            return;
        foreach (entry; array.array)
        {
            if (entry.type != JSONType.object)
                continue;
            const kind = liveString(liveChild(entry, "kind"), "ellipsoid");
            if (kind == "sphere")
            {
                const centre = liveNumbers(liveChild(entry, "center"));
                const radius = liveNumber(liveChild(entry, "radius"), 0.05);
                if (centre.length >= 3)
                    into ~= sphere(Vec3(centre[0], centre[1], centre[2]),
                        radius);
            }
            else if (kind == "taper")
            {
                const start = liveNumbers(liveChild(entry, "a"));
                const end = liveNumbers(liveChild(entry, "b"));
                const startRadius = liveNumber(liveChild(entry, "r0"), 0.03);
                const endRadius = liveNumber(liveChild(entry, "r1"), 0.03);
                if (start.length >= 3 && end.length >= 3)
                    into ~= taper(Vec3(start[0], start[1], start[2]),
                        Vec3(end[0], end[1], end[2]), startRadius, endRadius);
            }
            else
            {
                const centre = liveNumbers(liveChild(entry, "center"));
                const radii = liveNumbers(liveChild(entry, "radii"));
                if (centre.length >= 3 && radii.length >= 3)
                    into ~= ellipsoid(Vec3(centre[0], centre[1], centre[2]),
                        Vec3(radii[0], radii[1], radii[2]));
            }
        }
    }

    /// Draw the active region's volume as a translucent wireframe over the view.
    private void drawRegionOverlay(Canvas canvas, int width, int height)
    {
        auto region = activeRegion();
        if (region is null || width <= 0 || height <= 0)
            return;
        auto low = Vec3(
            region.a.x < region.b.x ? region.a.x : region.b.x,
            region.a.y < region.b.y ? region.a.y : region.b.y,
            region.a.z < region.b.z ? region.a.z : region.b.z);
        auto high = Vec3(
            region.a.x > region.b.x ? region.a.x : region.b.x,
            region.a.y > region.b.y ? region.a.y : region.b.y,
            region.a.z > region.b.z ? region.a.z : region.b.z);
        if (region.kind != RegionKind.box)
        {
            const pad = Vec3(region.radius, region.radius, region.radius);
            low = meshAdd(low, meshScale(pad, -1.0));
            high = meshAdd(high, pad);
        }
        const Vec3[8] corners = [
            Vec3(low.x, low.y, low.z), Vec3(high.x, low.y, low.z),
            Vec3(high.x, high.y, low.z), Vec3(low.x, high.y, low.z),
            Vec3(low.x, low.y, high.z), Vec3(high.x, low.y, high.z),
            Vec3(high.x, high.y, high.z), Vec3(low.x, high.y, high.z),
        ];
        static immutable int[2][12] edges = [
            [0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6],
            [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7],
        ];
        const ink = Color.rgba(45, 212, 191, 110);
        foreach (edge; edges)
        {
            const from = project(corners[edge[0]], _camera, width, height);
            const to = project(corners[edge[1]], _camera, width, height);
            if (!from.visible || !to.visible)
                continue;
            const steps = cast(int) max(abs(to.x - from.x), abs(to.y - from.y));
            foreach (step; 0 .. steps + 1)
            {
                const t = steps == 0 ? 0.0 : cast(double) step / steps;
                const x = cast(int) (from.x + (to.x - from.x) * t);
                const y = cast(int) (from.y + (to.y - from.y) * t);
                if (x >= 0 && y >= 0 && x < width && y < height)
                    canvas.fillRect(Rect(x, y, 1, 1), ink);
            }
        }
    }

    /// Apply one replacement, optionally recording it so it survives a rebake.
    private bool applyReplaceCommand(JSONValue command, bool record)
    {
        const kind = liveString(liveChild(command, "kind"), "subdivide");
        const minimum = meshMinimum(_mesh);
        const maximum = meshMaximum(_mesh);
        auto candidate = cloneMesh(_mesh);
        const start = MonoTime.currTime();
        int changed;
        if (kind == "subdivide")
            changed = subdivideMesh(candidate,
                cast(int) liveNumber(liveChild(command, "passes"), 1));
        else if (kind == "decimate")
            changed = decimateTo(candidate,
                cast(int) liveNumber(liveChild(command, "faces"),
                    cast(int) candidate.faces.length / 2));
        else if (kind == "sdf")
        {
            const name = liveString(liveChild(command, "region"),
                _activeRegion);
            auto region = name in _regions;
            if (region is null)
            {
                _lastReplaceOk = false;
                _lastReplaceReason = "no region to place the shape";
                return false;
            }
            SdfField field;
            readSdfShapes(liveChild(command, "shapes"), field.shapes);
            readSdfShapes(liveChild(command, "cuts"), field.cuts);
            field.blend = liveNumber(liveChild(command, "blend"),
                field.blend);
            changed = addSdfShell(candidate, *region, field,
                liveNumber(liveChild(command, "cell"), 0.006), _shellLo,
                _shellHi, _shellFaces);
        }
        _lastOpMs = (MonoTime.currTime() - start).total!"usecs" / 1000.0;
        // Commit only if the result is still a sound mesh.
        string reason;
        const ok = changed != 0 &&
            replaceChecked(_mesh, candidate, minimum, maximum, reason);
        _lastReplaceOk = ok;
        _lastReplaceReason = ok ? "ok" : (changed == 0 ?
            "nothing to do" : reason);
        _lastOp = kind;
        if (ok && record)
            _replaceCommands ~= command;
        return ok;
    }

    /// Replay accepted replacements onto a freshly baked mesh.
    private void applyReplacements()
    {
        if (_replaceCommands.length == 0)
            return;
        foreach (command; _replaceCommands)
            applyReplaceCommand(command, false);
    }

    private void writeLiveAck()
    {
        try
            writeReport("build/live-ack.json", format(
                `{"revision":%d,"status":"ok","objects":%d,"poses":%d,"clip":"%s","frame":%d,"frames":%d,"playing":%s,"tracks":%d,"keys":%d,"valid":%s,"nonFinite":%d,"invalidFaces":%d,"warnings":"%s","frameScan":%d,"invalidFrames":%d,"limbHits":%d,"collisionFrames":%d,"collisionPairs":%d,"scanRunning":%s,"scanFrame":%d,"scanTotal":%d,"ticks":%d,"advances":%d,"renderer":"%s","hardware":%s,"rendererFallback":"%s","awarenessValid":%s,"frameScanPath":"build/live-frames.json","capture":"%s","sheet":"%s","collisions":%d,"baselineCollisions":%d,"collisionSample":[%.4f,%.4f,%.4f],"collisionFaces":[%d,%d],"follows":%d,"clusterFaces":%d,"strayFaces":%d,"reshape":"%s","reshaped":%d,"reshapeMs":%.2f,"regions":%d,"region":"%s","maskVerts":%d,"maskFaces":%d,"op":"%s","opMs":%.2f,"replaceOk":%s,"replaceReason":"%s","shellFaces":%d,"shellLo":[%.3f,%.3f,%.3f],"shellHi":[%.3f,%.3f,%.3f]}`,
                _liveRevision, _liveExtras.length, _poseOverrides.length,
                jsonEscape(_hasLiveAnimation ? _liveClip.name : ""),
                cast(int) (_time * 30 + 0.5), animationFrameCount(),
                _playing ? "true" : "false",
                animationTrackCount(), animationKeyCount(),
                _auditValid ? "true" : "false", _auditNonFinite,
                _auditInvalidFaces, jsonEscape(_auditWarnings.join("|")),
                _scanFrameCount, _scanInvalidFrames, _scanLimbHits,
                _scanCollisionFrames, _scanCollisionPairs,
                _scanRunning ? "true" : "false", _scanCursor,
                _scanFrameCount, _scanTickCount, _scanAdvanceCount,
                jsonEscape(_rendererName),
                _rendererHardware ? "true" : "false",
                jsonEscape(_rendererFallback),
                _scanFrameCount > 0 && _scanInvalidFrames == 0 ? "true" : "false",
                jsonEscape(_lastCapturePath),
                jsonEscape(_lastSheetPath),
                _collisions.pairs, _baselineCollisionCount,
                _collisions.sample.x, _collisions.sample.y,
                _collisions.sample.z, _collisions.faceA, _collisions.faceB,
                _liveFollowCount, _baselineClusterFaces, _baselineStrayFaces,
                jsonEscape(_lastReshape), _lastReshaped, _lastReshapeMs,
                _regions.length, jsonEscape(_activeRegion), _maskVertices,
                _maskFaces, jsonEscape(_lastOp), _lastOpMs,
                _lastReplaceOk ? "true" : "false",
                jsonEscape(_lastReplaceReason), _shellFaces, _shellLo.x,
                _shellLo.y, _shellLo.z, _shellHi.x, _shellHi.y, _shellHi.z));
        catch (Exception)
        {
        }
    }

    private void rebuildGltfMesh()
    {
        if (!_hasScene)
            return;
        Mat4[] worlds;
        _mesh = bakeGltfFrame(_scene, _animation, _time, true,
            effectivePoseOverrides(), &worlds);
        _nodeWorlds = worlds;
        if (_liveExtras.length > 0)
        {
            foreach (extra; _liveExtras)
            {
                if (extra.mesh.vertices.length == 0)
                    continue;
                Mesh extraMesh = extra.mesh;
                if (extra.hasRotation)
                    foreach (ref vertex; extraMesh.vertices)
                        vertex = gltfRotateVector(extra.rotation, vertex);
                if (extra.hasRotation &&
                    extraMesh.normals.length == extraMesh.vertices.length)
                    foreach (ref normal; extraMesh.normals)
                        normal = gltfRotateVector(extra.rotation, normal);
                foreach (ref vertex; extraMesh.vertices)
                    vertex = meshAdd(vertex, extra.offset);
                if (extra.node >= 0 && extra.node < worlds.length)
                    foreach (ref vertex; extraMesh.vertices)
                        vertex = gltfTransformPoint(worlds[extra.node],
                            vertex);
                if (extraMesh.normals.length == extraMesh.vertices.length &&
                    extra.node >= 0 && extra.node < worlds.length)
                    foreach (ref normal; extraMesh.normals)
                        normal = gltfTransformNormal(worlds[extra.node], normal);
                const offset = cast(int) _mesh.vertices.length;
                _mesh.vertices ~= extraMesh.vertices;
                _mesh.normals ~= extraMesh.normals;
                if (_mesh.uvs.length == offset)
                    foreach (vertex; extraMesh.vertices)
                        _mesh.uvs ~= Vec2(0, 0);
                MaterialSlot slot;
                slot.baseColor = extra.color;
                slot.doubleSided = true;
                const materialIndex = cast(int) _mesh.materials.length;
                _mesh.materials ~= slot;
                foreach (face; extraMesh.faces)
                {
                    const before = _mesh.faces.length;
                    _mesh.addTriangle(offset + face.a, offset + face.b,
                        offset + face.c, Material.neutral);
                    if (_mesh.faces.length > before)
                        _mesh.faceMaterials ~= materialIndex;
                }
            }
        }
        applyReshapes();
        // Replacements are replayed onto the fresh bake, so an accepted shell or
        // subdivision is not lost the next time the mesh is rebuilt.
        applyReplacements();
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
            _hasLiveAnimation = false;
            _liveClip = LiveClip();
            _playing = false;
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
            _replaceCommands.length = 0;
            _reshapecs.length = 0;
            _regions = null;
            _activeRegion = "";
            _poseOverrides.length = 0;
            _hasLiveAnimation = false;
            _liveClip = LiveClip();
            _playing = false;
            return true;
        }
        if (type == "check")
        {
            _checkCollisions = true;
            return true;
        }
        if (type == "keyframe")
            return applyLiveKeyframe(command, false);
        if (type == "remove-keyframe")
            return applyLiveKeyframe(command, true);
        if (type == "audit")
            return true;
        if (type == "scan-frames")
        {
            _scanCollisions = liveHas(command, "collisions") &&
                liveChild(command, "collisions").type == JSONType.true_;
            _scanIgnorePartNames.length = 0;
            const ignoreParts = liveChild(command, "ignoreParts");
            if (ignoreParts.type == JSONType.array)
                foreach (entry; ignoreParts.array)
                    if (entry.type == JSONType.string)
                        _scanIgnorePartNames ~= entry.str;
            _scanIncremental = liveHas(command, "incremental") &&
                liveChild(command, "incremental").type == JSONType.true_;
            _scanCancelRequested = false;
            _scanRequested = true;
            return true;
        }
        if (type == "cancel-scan")
        {
            _scanCancelRequested = true;
            return true;
        }
        if (type == "inspect-bone")
        {
            const name = liveString(liveChild(command, "node"));
            int node = liveNodeIndex(name);
            if (node < 0 && liveHas(command, "node"))
                node = cast(int) liveInteger(liveChild(command, "node"));
            if (node < 0 || node >= _scene.nodes.length)
                return false;
            _inspectNode = node;
            return true;
        }
        if (type == "list-bones")
        {
            _listBones = true;
            return true;
        }
        if (type == "pose-axis")
        {
            const name = liveString(liveChild(command, "node"));
            int node = liveNodeIndex(name);
            if (node < 0 && liveHas(command, "node"))
                node = cast(int) liveInteger(liveChild(command, "node"));
            if (node < 0 || node >= _scene.nodes.length)
                return false;
            const axisName = liveString(liveChild(command, "axis"), "x");
            const angle = liveNumber(liveChild(command, "angle")) *
                3.141592653589793 / 180.0;
            const half = angle * 0.5;
            PoseOverride overrideValue;
            overrideValue.node = node;
            overrideValue.hasRotation = true;
            overrideValue.rotation = [0.0, 0.0, 0.0, cos(half)];
            if (axisName == "x")
                overrideValue.rotation[0] = sin(half);
            else if (axisName == "y")
                overrideValue.rotation[1] = sin(half);
            else
                overrideValue.rotation[2] = sin(half);
            overrideValue.additive = !(liveHas(command, "additive") &&
                liveChild(command, "additive").type == JSONType.false_);
            _poseOverrides ~= overrideValue;
            return true;
        }
        if (type == "pose-aim")
            return applyPoseAim(command);
        if (type == "reshape")
        {
            const region = liveString(liveChild(command, "region"), "feet");
            const style = liveString(liveChild(command, "style"), "toes");
            const strength = liveNumber(liveChild(command, "strength"), 1.0);
            RegionEdit incoming;
            incoming.region = region;
            incoming.style = style;
            incoming.strength = strength;
            // A volume can be named or given outright, so any part of the body
            // can be edited without new code.
            const corners = liveNumbers(liveChild(command, "box"));
            if (corners.length >= 6)
            {
                incoming.hasBox = true;
                incoming.box = RegionBox(
                    Vec3(corners[0], corners[1], corners[2]),
                    Vec3(corners[3], corners[4], corners[5]));
            }
            else
            {
                // An unknown name would silently do nothing, so refuse it.
                const box = regionBox(region);
                if (box.minimum == box.maximum)
                    return false;
            }
            if (style == "none" || style == "reset")
            {
                foreach (index, edit; _reshapecs)
                    if (edit.region == region)
                    {
                        _reshapecs = _reshapecs[0 .. index] ~
                            _reshapecs[index + 1 .. $];
                        break;
                    }
            }
            else
            {
                // One edit per region: asking again for the same region
                // replaces the style instead of stacking deformations.
                bool replaced;
                foreach (ref edit; _reshapecs)
                    if (edit.region == region)
                    {
                        edit = incoming;
                        replaced = true;
                    }
                if (!replaced)
                    _reshapecs ~= incoming;
            }
            _lastReshape = region ~ ":" ~ style;
            // A scene mesh is rebaked per frame, so ask for a rebake and let it
            // replay every recorded edit; a static mesh is edited in place.
            if (_hasScene)
                rebuildGltfMesh();
            else
                applyReshapes();
            _dirty = true;
            invalidate();
            return _lastReshaped > 0;
        }
        if (type == "region")
        {
            const name = liveString(liveChild(command, "name"), "region");
            RegionVolume volume;
            volume.name = name;
            const kind = liveString(liveChild(command, "kind"), "box");
            volume.kind = kind == "sphere" ? RegionKind.sphere :
                kind == "capsule" ? RegionKind.capsule : RegionKind.box;
            const first = liveNumbers(liveChild(command, "a"));
            const second = liveNumbers(liveChild(command, "b"));
            if (first.length >= 3)
                volume.a = Vec3(first[0], first[1], first[2]);
            if (second.length >= 3)
                volume.b = Vec3(second[0], second[1], second[2]);
            volume.radius = liveNumber(liveChild(command, "radius"),
                volume.radius);
            volume.falloff = liveNumber(liveChild(command, "falloff"),
                volume.falloff);
            _regions[name] = volume;
            _activeRegion = name;
            refreshMaskStats();
            tintSelection();
            _dirty = true;
            invalidate();
            return true;
        }
        if (type == "region-clear")
        {
            _regions = null;
            _activeRegion = "";
            refreshMaskStats();
            _dirty = true;
            invalidate();
            return true;
        }
        if (type == "deform")
        {
            const name = liveString(liveChild(command, "region"), _activeRegion);
            auto region = name in _regions;
            if (region is null)
                return false;
            const op = liveString(liveChild(command, "op"), "inflate");
            const amount = liveNumber(liveChild(command, "amount"), 0.01);
            const direction = liveNumbers(liveChild(command, "direction"));
            const aim = direction.length >= 3 ?
                Vec3(direction[0], direction[1], direction[2]) : Vec3(0, 0, 0);
            // One snapshot per edit, so undo steps back a whole move.
            _undo ~= cloneMesh(_mesh);
            const start = MonoTime.currTime();
            const moved = deformRegion(_mesh, *region, op, amount, aim);
            _lastOpMs = (MonoTime.currTime() - start).total!"usecs" / 1000.0;
            _lastOp = op;
            _activeRegion = name;
            refreshMaskStats();
            tintSelection();
            _dirty = true;
            invalidate();
            return moved > 0;
        }
        if (type == "replace")
        {
            const ok = applyReplaceCommand(command, true);
            refreshMaskStats();
            tintSelection();
            _dirty = true;
            invalidate();
            return ok;
        }
        if (type == "capture")
        {
            _capturePath = liveString(liveChild(command, "path"),
                "build/live-capture.ppm");
            return true;
        }
        if (type == "capture-sheet")
        {
            _sheetPath = liveString(liveChild(command, "path"),
                "build/live-sheet.ppm");
            return true;
        }
        if (type == "new-animation")
            return applyLiveAnimation(command);
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
            _hasLiveAnimation = false;
            _liveClip = LiveClip();
            buildCollisionBaseline();
            return true;
        }
        if (type == "time")
        {
            _time = liveNumber(liveChild(command, "time"));
            return true;
        }
        if (type == "frame")
        {
            _time = liveNumber(liveChild(command, "frame")) / 30.0;
            _playing = false;
            return true;
        }
        if (type == "pause")
        {
            _playing = false;
            return true;
        }
        if (type == "object")
        {
            const shape = liveString(liveChild(command, "shape"), "box");
            const position = liveVector(liveChild(command, "position"),
                Vec3(0, 1.2, 0));
            const scale = liveNumber(liveChild(command, "scale"), 1.0);
            const path = liveString(liveChild(command, "path"));
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
            LiveExtra extra;
            if (path.length > 0)
            {
                try
                    extra.mesh = parseObj(readText(path));
                catch (Exception)
                    return false;
                foreach (ref vertex; extra.mesh.vertices)
                    vertex = Vec3(vertex.x * scale, vertex.y * scale,
                        vertex.z * scale);
                computeSmoothNormals(extra.mesh);
            }
            else
                extra.mesh = liveObject(shape, Vec3(0, 0, 0), scale);
            extra.node = node;
            extra.offset = liveVector(liveChild(command, "offset"), position);
            const rotation = liveNumbers(liveChild(command, "rotation"));
            if (rotation.length >= 4)
            {
                extra.hasRotation = true;
                extra.rotation = [rotation[0], rotation[1], rotation[2],
                    rotation[3]];
            }
            const color = liveNumbers(liveChild(command, "color"));
            if (color.length >= 3)
                extra.color = Vec3(color[0], color[1], color[2]);
            _liveExtras ~= extra;
            return true;
        }
        if (type == "save")
        {
            const path = liveString(liveChild(command, "path"));
            if (path.length == 0)
                return false;
            _pendingSavePath = path;
            return false;
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

    private bool applyLiveAnimation(JSONValue command)
    {
        const name = liveString(liveChild(command, "name"), "Live animation");
        const tracksValue = liveChild(command, "tracks");
        if (tracksValue.type != JSONType.array)
            return false;
        LiveTrack[] tracks;
        double maxTime;
        const additiveClip = liveHas(command, "additive") &&
            liveChild(command, "additive").type == JSONType.true_;
        Mat4[] base;
        bool haveBase;
        foreach (trackValue; tracksValue.array)
        {
            const nodeName = liveString(liveChild(trackValue, "node"));
            int node = -1;
            foreach (index, value; _scene.nodes)
                if (value.name == nodeName)
                {
                    node = cast(int) index;
                    break;
                }
            if (node < 0 && liveHas(trackValue, "node"))
                node = cast(int) liveInteger(liveChild(trackValue, "node"));
            if (node < 0 || node >= _scene.nodes.length)
                continue;
            const keysValue = liveChild(trackValue, "keys");
            if (keysValue.type != JSONType.array)
                continue;
            LiveTrack track;
            track.node = node;
            foreach (keyValue; keysValue.array)
            {
                LiveKey key;
                key.time = liveNumber(liveChild(keyValue, "time"));
                const translation = liveNumbers(
                    liveChild(keyValue, "translation"));
                if (translation.length >= 3)
                {
                    key.hasTranslation = true;
                    key.translation = Vec3(translation[0], translation[1],
                        translation[2]);
                }
                const rotation = liveNumbers(liveChild(keyValue, "rotation"));
                if (rotation.length >= 4)
                {
                    key.hasRotation = true;
                    key.rotation = [rotation[0], rotation[1], rotation[2],
                        rotation[3]];
                }
                else if (liveHas(keyValue, "worldAxis"))
                {
                    // Author in world terms: the axis is resolved against the
                    // node's base pose, so a wave is "spin world Z".
                    const worldAxis = liveAxisValue(
                        liveChild(keyValue, "worldAxis"));
                    if (length(worldAxis) > 1.0e-9)
                    {
                        if (!haveBase)
                        {
                            base = baseWorldMatrices();
                            haveBase = true;
                        }
                        key.hasRotation = true;
                        key.rotation = worldAxisKeyRotation(base, node,
                            worldAxis, liveNumber(liveChild(keyValue, "angle")),
                            additiveClip);
                        key.hasWorldAxis = true;
                        key.worldAxis = worldAxis;
                        key.worldAngle = liveNumber(
                            liveChild(keyValue, "angle"));
                    }
                }
                const scale = liveNumbers(liveChild(keyValue, "scale"));
                if (scale.length >= 3)
                {
                    key.hasScale = true;
                    key.scale = Vec3(scale[0], scale[1], scale[2]);
                }
                track.keys ~= key;
                maxTime = max(maxTime, key.time);
            }
            if (track.keys.length == 0)
                continue;
            track.keys.sort!((a, b) => a.time < b.time);
            tracks ~= track;
        }
        _liveFollowCount = 0;
        if (!additiveClip && liveHas(command, "follow") &&
            liveChild(command, "follow").type == JSONType.array)
            foreach (followValue; liveChild(command, "follow").array)
            {
                const socket = liveNodeIndex(
                    liveString(liveChild(followValue, "node")));
                const target = liveNodeIndex(
                    liveString(liveChild(followValue, "target")));
                if (socket < 0 || target < 0 || socket == target)
                    continue;
                int targetTrack = -1;
                foreach (index, track; tracks)
                    if (track.node == target)
                    {
                        targetTrack = cast(int) index;
                        break;
                    }
                if (targetTrack < 0)
                    continue;
                if (!haveBase)
                {
                    base = baseWorldMatrices();
                    haveBase = true;
                }
                const pivot = Vec3(base[target].m[12], base[target].m[13],
                    base[target].m[14]);
                const rest = Vec3(base[socket].m[12], base[socket].m[13],
                    base[socket].m[14]);
                const socketParent = parentNode(socket);
                LiveTrack followed;
                followed.node = socket;
                foreach (key; tracks[targetTrack].keys)
                {
                    if (!key.hasWorldAxis)
                        continue;
                    LiveKey socketKey;
                    socketKey.time = key.time;
                    socketKey.hasRotation = true;
                    socketKey.rotation = worldAxisKeyRotation(base, socket,
                        key.worldAxis, key.worldAngle, false);
                    socketKey.hasWorldAxis = true;
                    socketKey.worldAxis = key.worldAxis;
                    socketKey.worldAngle = key.worldAngle;
                    socketKey.hasTranslation = true;
                    const orbit = rotateAroundAxis(key.worldAxis,
                        key.worldAngle, Vec3(rest.x - pivot.x,
                            rest.y - pivot.y, rest.z - pivot.z));
                    socketKey.translation = parentSpacePosition(base,
                        socketParent, Vec3(pivot.x + orbit.x,
                            pivot.y + orbit.y, pivot.z + orbit.z));
                    followed.keys ~= socketKey;
                }
                if (followed.keys.length == 0)
                    continue;
                bool replaced;
                foreach (ref track; tracks)
                    if (track.node == socket)
                    {
                        track = followed;
                        replaced = true;
                        break;
                    }
                if (!replaced)
                    tracks ~= followed;
                _liveFollowCount++;
            }

        if (tracks.length == 0)
            return false;
        _liveClip = LiveClip();
        _liveClip.name = name;
        _liveClip.tracks = tracks;
        _liveClip.duration = liveNumber(liveChild(command, "duration"),
            maxTime > 0 ? maxTime : 1.0);
        _liveClip.loop = !(liveHas(command, "loop") &&
            liveChild(command, "loop").type == JSONType.false_);
        _liveClip.additive = liveHas(command, "additive") &&
            liveChild(command, "additive").type == JSONType.true_;
        _hasLiveAnimation = true;
        _playing = true;
        _time = 0;
        const avoid = liveHas(command, "avoidCollisions") &&
            liveChild(command, "avoidCollisions").type == JSONType.true_;
        if (avoid)
            avoidAnimationCollisions();
        return true;
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
            options.cullBackfaces = _cull;
            options.selectedVertex = _selected;
            _frame = renderMesh(_mesh, _camera, viewportWidth, viewportHeight,
                options);
            _frameWidth = viewportWidth;
            _frameHeight = viewportHeight;
            _dirty = false;
        }

        canvas.drawRgbImage(Rect(0, 0, viewportWidth, viewportHeight),
            _frame.width, _frame.height, _frame.pixels, false);
        drawRegionOverlay(canvas, viewportWidth, viewportHeight);
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
        if (_hasLiveAnimation && _liveClip.duration > 0)
        {
            const barX = 18;
            const barY = height - 54;
            const barW = max(1, viewportWidth - 36);
            canvas.fillRect(Rect(barX, barY, barW, 34),
                Color.rgba(8, 15, 28, 225));
            canvas.fillRect(Rect(barX, barY + 16, barW, 2),
                Color.rgba(71, 85, 105, 220));
            const frames = max(1, animationFrameCount());
            foreach (frame; 0 .. frames + 1)
            {
                const x = barX + barW * frame / frames;
                canvas.fillRect(Rect(x, barY + 12, 1, 8),
                    Color.rgba(100, 116, 139, 150));
            }
            foreach (track; _liveClip.tracks)
                foreach (key; track.keys)
                {
                    const x = barX + cast(int) (barW *
                        (key.time / _liveClip.duration));
                    canvas.fillRect(Rect(x, barY + 6, 2, 21), accent);
                }
            const playhead = barX + cast(int) (barW *
                min(1.0, max(0.0, _time / _liveClip.duration)));
            canvas.fillRect(Rect(playhead, barY + 2, 2, 29), warn);
            label(canvas, Rect(barX, barY - 20, barW, 18),
                format("%s  F %d/%d  ·  %d tracks / %d keys  ·  %s",
                    _liveClip.name, cast(int) (_time * 30 + 0.5), frames,
                    animationTrackCount(), animationKeyCount(),
                    _auditValid ? "OK" : "CHECK WARNINGS"),
                _auditValid ? accent : warn, 1);
        }
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
            format("TOOL  %s%s%s", toolName(), _symmetry ? " · mirror X" : "",
                _cull ? "" : " · culling off"),
            _symmetry ? accent : white, 1);
        if (_hasLiveAnimation || (_hasScene && _scene.animations.length > 0))
            label(canvas, Rect(left, 196, inner, 20),
                format("ANIM  %s  %.2fs%s",
                    _hasLiveAnimation ? _liveClip.name :
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
            "U: undo · C: cull faces",
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
        if (_hasLiveAnimation || (_hasScene && _scene.animations.length > 0))
            label(canvas, Rect(14, 36, 620, 20),
                format("F %d/%d · %s · %d trk / %d keys · %s",
                    cast(int) (_time * 30 + 0.5), animationFrameCount(),
                    _hasLiveAnimation ? _liveClip.name :
                    _scene.animations[_animation].name,
                    animationTrackCount(), animationKeyCount(),
                    _auditValid ? "OK" : _auditWarnings.join(" / ")),
                _auditValid ? Color.rgba(45, 212, 191, 235) :
                Color.rgba(251, 191, 36, 235), 1);
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
            case Key.c:
                _cull = !_cull;
                _dirty = true;
                _status = _cull ? "Backface culling on" :
                    "Backface culling off (all faces drawn)";
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
                if (_hasLiveAnimation ||
                    (_hasScene && _scene.animations.length > 0))
                {
                    _playing = !_playing;
                    _status = _playing ? "Playing " ~
                        (_hasLiveAnimation ? _liveClip.name :
                            _scene.animations[_animation].name) :
                        "Animation paused";
                    invalidate();
                    return true;
                }
                return false;
            case Key.n:
                if (_hasLiveAnimation)
                {
                    _time = 0;
                    _playing = true;
                    rebuildGltfMesh();
                    _status = "Animation: " ~ _liveClip.name;
                    invalidate();
                    return true;
                }
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
                if (_hasLiveAnimation)
                {
                    _time += event.key == Key.leftBracket ? -0.1 : 0.1;
                    if (_liveClip.duration > 0)
                    {
                        while (_time < 0)
                            _time += _liveClip.duration;
                        while (_time >= _liveClip.duration)
                            _time -= _liveClip.duration;
                    }
                    rebuildGltfMesh();
                    _status = format("Animation time %.2fs", _time);
                    invalidate();
                    return true;
                }
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
            case Key.comma:
            case Key.period:
                if (_hasLiveAnimation || (_hasScene &&
                    _scene.animations.length > 0))
                {
                    _playing = false;
                    const duration = _hasLiveAnimation ? _liveClip.duration :
                        gltfAnimationDuration(_scene, _animation);
                    _time += event.key == Key.period ? 1.0 / 30.0 :
                        -1.0 / 30.0;
                    if (duration > 0)
                    {
                        while (_time < 0)
                            _time += duration;
                        while (_time >= duration)
                            _time -= duration;
                    }
                    rebuildGltfMesh();
                    _status = format("Frame %d / %d",
                        cast(int) (_time * 30 + 0.5),
                        duration > 0 ? cast(int) (duration * 30 + 0.5) : 0);
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
            case 9:
            case 10:
                reshapeFeet(button == 9 ? "foot" : "boot");
                break;
            default:
                break;
        }
        invalidate();
    }

    /// Re-form the feet in one click. Recorded as state, so the style survives
    /// the next rebake instead of being lost with the old vertices.
    private void reshapeFeet(string style)
    {
        bool replaced;
        foreach (ref edit; _reshapecs)
            if (edit.region == "feet")
            {
                edit.style = style;
                replaced = true;
            }
        if (!replaced)
            _reshapecs ~= RegionEdit("feet", style, 1.0);
        _undo ~= cloneMesh(_mesh);
        if (_hasScene)
            rebuildGltfMesh();
        else
            applyReshapes();
        _lastReshape = "feet:" ~ style;
        _dirty = true;
        _status = format("Feet: %s (%d vertices, %.1f ms)", style,
            _lastReshaped, _lastReshapeMs);
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
        int[] selected = brushVertices(_mesh, _camera, width, height,
            point.x, point.y, BrushRadius);
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
        auto unique = new bool[_mesh.vertices.length];
        int[] distinct;
        foreach (index; selected)
            if (!unique[index])
            {
                unique[index] = true;
                distinct ~= index;
            }
        selected = distinct;
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
