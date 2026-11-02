module auroraopencode.conversationview;

import auroraopencode.core : ToolState, toolStateName, parseToolState;
import std.json : JSONValue, JSONType;

public struct ConversationToolView
{
    string id, name, arguments, output;
    ToolState state = ToolState.queued;
    long elapsedMs;
    bool started;
}

public struct ConversationExecutionView
{
    string phase, routingKey;
    uint resendCount;
    long retryRemainingMs = -1;
    int toolRounds;
    size_t selectedImages, selectedImageBytes, imageSizeReads, imageBlobReads;
    ConversationToolView[] tools;
    size_t omittedTools;
}

public JSONValue toolViewJson(const ref ConversationToolView tool)
{
    JSONValue value;
    static foreach (field; ["id", "name", "arguments", "output", "elapsedMs", "started"])
        value[field] = __traits(getMember, tool, field);
    value["state"] = toolStateName(tool.state);
    return value;
}

public ConversationToolView decodeToolView(const ref JSONValue value)
{
    ConversationToolView tool;
    tool.id = value["id"].str; tool.name = value["name"].str;
    tool.arguments = value["arguments"].str; tool.output = value["output"].str;
    tool.state = parseToolState(value["state"].str);
    tool.elapsedMs = value["elapsedMs"].integer; tool.started = value["started"].boolean;
    if (!tool.id.length) throw new Exception("Live tool view has no identity");
    return tool;
}

public JSONValue executionViewJson(const ref ConversationExecutionView execution)
{
    JSONValue value;
    static foreach (field; ["phase", "routingKey", "resendCount", "retryRemainingMs", "toolRounds",
        "selectedImages", "selectedImageBytes", "imageSizeReads", "imageBlobReads", "omittedTools"])
        value[field] = __traits(getMember, execution, field);
    value["tools"] = JSONValue.emptyArray;
    foreach (tool; execution.tools) value["tools"].array ~= toolViewJson(tool);
    return value;
}

public ConversationExecutionView decodeExecutionView(const ref JSONValue value)
{
    ConversationExecutionView result;
    if (value.type != JSONType.object) return result;
    if (auto field = "phase" in value.object) result.phase = field.str;
    if (auto field = "routingKey" in value.object) result.routingKey = field.str;
    static foreach (field; ["resendCount", "retryRemainingMs", "toolRounds", "selectedImages",
        "selectedImageBytes", "imageSizeReads", "imageBlobReads", "omittedTools"])
        if (auto number = field in value.object)
            __traits(getMember, result, field) = cast(typeof(__traits(getMember, result, field))) number.integer;
    if (auto tools = "tools" in value.object)
        foreach (tool; tools.array) result.tools ~= decodeToolView(tool);
    return result;
}
