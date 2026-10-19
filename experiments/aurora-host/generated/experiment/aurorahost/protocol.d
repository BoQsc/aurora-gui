module experiment.aurorahost.protocol;

/**
 * Generated from protocol/aurora-host.api.json.
 * Do not edit manually; run tools/generate_reference.py.
 */

enum ExperimentVersion = "0.1.0";
enum ProtocolVersion = 1;
enum SchemaVersion = 1;

immutable string[] Capabilities = [
    "window",
    "scene",
    "label",
    "button",
    "row",
    "column",
    "spacer",
    "headless-render",
    "control-stdin",
    "text-editor",
];

immutable string[] NodeTypes = [
    "column",
    "row",
    "label",
    "button",
    "textArea",
    "spacer",
];

enum MaxSceneDepth = 16;
enum MaxSceneNodes = 256;
