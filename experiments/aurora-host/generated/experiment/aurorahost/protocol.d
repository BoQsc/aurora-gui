module experiment.aurorahost.protocol;

/**
 * Generated from protocol/aurora-host.api.json.
 * Do not edit manually; run tools/generate_reference.py.
 */

enum ExperimentVersion = "0.2.0";
enum ProtocolVersion = 2;
enum SchemaVersion = 2;

immutable string[] Capabilities = [
    "window",
    "scene",
    "canvas",
    "image",
    "surface",
    "label",
    "button",
    "row",
    "column",
    "spacer",
    "headless-render",
    "control-stdin",
    "text-editor",
    "assets",
    "pointer-events",
    "key-events",
    "frame-events",
    "shared-surface",
];

immutable string[] NodeTypes = [
    "column",
    "row",
    "label",
    "button",
    "textArea",
    "canvas",
    "image",
    "surface",
    "spacer",
];

enum MaxSceneDepth = 16;
enum MaxSceneNodes = 256;
enum MaxCanvasCommands = 4096;
enum MaxSurfacePixels = 4000000;
enum MaxInputEvents = 4096;

enum SurfaceMagic = "AURSFACE";
enum SurfaceVersion = 2;
enum SurfaceHeaderSize = 80;
enum SurfaceInputEventSize = 24;
enum SurfaceBufferCount = 2;
