module opencodelite.history;

import opencodelite.settings : defaultSettingsPath;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;

struct ConversationState
{
    string transcript = "New session.\n";
    uint messages;
    string lastPrompt;
    bool failed;
}

string conversationPath()
{
    return buildPath(dirName(defaultSettingsPath()), "conversation.json");
}

ConversationState loadConversation()
{
    ConversationState state;
    const path = conversationPath();
    if (!exists(path))
        return state;
    try
    {
        const document = parseJSON(readText(path));
        if (auto value = "transcript" in document.object)
            if (value.type == JSONType.string && value.str.length > 0)
                state.transcript = value.str;
        if (auto value = "messages" in document.object)
            if (value.type == JSONType.integer && value.integer >= 0)
                state.messages = cast(uint) value.integer;
        if (auto value = "lastPrompt" in document.object)
            if (value.type == JSONType.string)
                state.lastPrompt = value.str;
        if (auto value = "failed" in document.object)
            if (value.type == JSONType.true_ || value.type == JSONType.false_)
                state.failed = value.get!bool;
    }
    catch (Exception)
    {
        return ConversationState();
    }
    return state;
}

void saveConversation(in ConversationState state)
{
    const path = conversationPath();
    const directory = dirName(path);
    if (directory.length != 0 && !exists(directory))
        mkdirRecurse(directory);
    JSONValue document;
    document["transcript"] = state.transcript;
    document["messages"] = JSONValue(cast(long) state.messages);
    document["lastPrompt"] = state.lastPrompt;
    document["failed"] = state.failed;
    write(path, document.toString() ~ "\n");
}