module experiment.aurorahost.protocol;

/**
 * Generated from protocol/aurora-host.api.json.
 * Do not edit manually; run tools/generate_reference.py.
 */

enum ExperimentVersion = "0.4.4";
enum ProtocolVersion = 8;
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
    "text-field",
    "text-selection",
    "editor-view",
    "editor-styles",
    "editor-font-zoom",
    "editor-events",
    "assets",
    "pointer-events",
    "key-events",
    "frame-events",
    "shared-surface",
    "menu",
    "dynamic-menu",
    "tabs",
    "separator",
    "popup-menu",
    "context-menu",
    "ui-test-driver",
    "tooltips",
];

immutable string[] NodeTypes = [
    "column",
    "row",
    "label",
    "button",
    "menu",
    "tabs",
    "separator",
    "textArea",
    "textField",
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
