module auroraopencode_pro_live_probe;

import auroraopencode.core : ChatRequestMessage, OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeClient;
import auroraopencode.tools : buildSystemPrompt, builtinToolDefinitions,
    executeTool;
import std.file : readText, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : environment, execute;
import std.stdio : writeln;
import std.string : replace;
import std.algorithm : map;
import std.array : array;

private string post(string bodyFile, string respFile, string key)
{
    auto result = execute(["curl.exe", "-sS", "-m", "150",
        "-H", "Authorization: Bearer " ~ key,
        "-H", "Content-Type: application/json",
        "--data-binary", "@" ~ bodyFile,
        "https://api.commandcode.ai/provider/v1/chat/completions",
        "-o", respFile]);
    if (result.status != 0)
    {
        writeln("curl failed: ", result.output);
        return "";
    }
    return readText(respFile);
}

int main()
{
    const workspace = `C:\Users\WINDOW~2\AppData\Local\Temp\opencode\live-ws`;
    const bodyFile = `C:\Users\WINDOW~2\AppData\Local\Temp\opencode\loop-req.json`;
    const respFile = `C:\Users\WINDOW~2\AppData\Local\Temp\opencode\loop-resp.json`;
    const apiKey = environment.get("AURORA_PROBE_KEY");
    if (apiKey.length == 0)
    {
        writeln("set AURORA_PROBE_KEY first");
        return 1;
    }
    auto client = new OpenCodeClient(
        "https://api.commandcode.ai/provider/v1", apiKey);
    writeln("workspace = ", workspace);

    ChatRequestMessage[] messages;
    ChatRequestMessage system;
    system.role = "system";
    system.content = buildSystemPrompt(false, workspace, "Windows");
    messages ~= system;
    ChatRequestMessage user;
    user.role = "user";
    user.content = environment.get("AURORA_PROBE_TASK",
        "Add an `add(int a, int b)` function to src/math.d, " ~
        "call it from src/app.d, and delete src/old.d. Make the file changes.");
    messages ~= user;

    foreach (round; 0 .. 10)
    {
        auto body = client.buildBodyForTesting(messages,
            builtinToolDefinitions(), "deepseek/deepseek-v4.1-flash", false);
        body = body.replace(`"stream":true`, `"stream":false`);
        write(bodyFile, body);
        const response = post(bodyFile, respFile, apiKey);
        if (response.length == 0) return 2;

        JSONValue root;
        try root = parseJSON(response);
        catch (Exception error)
        {
            writeln("bad json: ", error.msg, " :: ", response[0 .. 200]);
            return 3;
        }
        if (root.type != JSONType.object ||
            !("choices" in root.object) ||
            root["choices"].type != JSONType.array ||
            root["choices"].array.length == 0)
        {
            writeln("no choices: ", response[0 .. 300]);
            return 4;
        }
        auto message = root["choices"].array[0]["message"];
        string content = "content" in message.object &&
            message["content"].type == JSONType.string
            ? message["content"].str : "";

        OpenCodeToolCall[] calls;
        if (("tool_calls" in message.object) &&
            message["tool_calls"].type == JSONType.array)
        {
            foreach (call; message["tool_calls"].array)
            {
                OpenCodeToolCall c;
                if ("id" in call.object)
                    c.id = call["id"].str;
                if (("function" in call.object) &&
                    call["function"].type == JSONType.object)
                {
                    if ("name" in call["function"].object)
                        c.name = call["function"]["name"].str;
                    if ("arguments" in call["function"].object)
                        c.arguments = call["function"]["arguments"].str;
                }
                calls ~= c;
            }
        }

        auto names = calls.map!(c => c.name).array;
        if (calls.length == 0)
            writeln("round ", round, ": (final message)");
        else
            writeln("round ", round, ": ", names);
        if (calls.length == 0)
        {
            writeln("FINAL: ", content.length > 0 ? content : "(empty)");
            return 0;
        }

        ChatRequestMessage assistant;
        assistant.role = "assistant";
        assistant.content = content;
        assistant.toolCalls = calls;
        messages ~= assistant;
        foreach (call; calls)
        {
            auto outcome = executeTool(call, workspace);
            ChatRequestMessage tool;
            tool.role = "tool";
            tool.toolCallId = call.id;
            tool.content = outcome.output;
            messages ~= tool;
            writeln("   ", call.name, outcome.failed ? " [FAILED] " : " -> ",
                outcome.output.length > 120
                    ? outcome.output[0 .. 120] ~ "..." : outcome.output);
        }
    }
    writeln("stopped after 10 rounds (did not finish)");
    return 5;
}
