module auroraopencode_pro_live_probe;

import auroraopencode.core : ChatRequestMessage, OpenCodeToolCall, loadSettings;
import auroraopencode.opencode_client : OpenCodeClient;
import auroraopencode.tools : buildSystemPrompt, executeTool,
    nativeOnlyToolDefinitions;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment, execute;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.algorithm : map;
import std.array : array;

private string post(string url, string bodyFile, string respFile, string key)
{
    auto result = execute(["curl.exe", "-sS", "-m", "150",
        "-H", "Authorization: Bearer " ~ key,
        "-H", "Content-Type: application/json",
        "--data-binary", "@" ~ bodyFile,
        url,
        "-o", respFile]);
    if (result.status != 0)
    {
        writeln("curl failed: ", result.output);
        return "";
    }
    return readText(respFile);
}

int main(string[] args)
{
    const complexScenario = args.length > 1 && args[1] == "--complex";
    const workspace = buildPath(tempDir(), "aurora-opencode-live-e2e");
    const bodyFile = buildPath(workspace, "request.json");
    const respFile = buildPath(workspace, "response.json");
    if (exists(workspace)) rmdirRecurse(workspace);
    mkdirRecurse(buildPath(workspace, "source"));
    if (complexScenario)
    {
        write(buildPath(workspace, "source", "domain.d"),
            "module domain;\n\nstruct Task\n{\n    string title;\n" ~
            "    int priority;\n    bool done;\n}\n");
        write(buildPath(workspace, "source", "task_store.d"),
            "module task_store;\n\nimport domain;\n\nstruct TaskStore\n{\n" ~
            "    private Task[] tasks;\n\n    void add(string title, int priority)\n" ~
            "    {\n        tasks ~= Task(title, priority, false);\n    }\n\n" ~
            "    const(Task)[] all() const\n    {\n        return tasks;\n    }\n}\n");
        write(buildPath(workspace, "source", "report.d"),
            "module report;\n\nimport task_store;\n\n" ~
            "string formatPendingReport(ref TaskStore store)\n{\n" ~
            "    return \"TODO\\n\";\n}\n");
        write(buildPath(workspace, "source", "app.d"),
            "module app;\n\nimport std.stdio;\nimport report;\n" ~
            "import task_store;\n\nvoid main()\n{\n    TaskStore store;\n" ~
            "    store.add(\"Write docs\", 2);\n    store.add(\"Fix bug\", 5);\n" ~
            "    store.add(\"Refactor\", 5);\n    writeln(formatPendingReport(store));\n}\n");
    }
    else
    {
        write(buildPath(workspace, "source", "math.d"),
            "module math;\n\nint doubleValue(int value)\n{\n    return value * 2;\n}\n");
        write(buildPath(workspace, "source", "app.d"),
            "module app;\n\nimport std.stdio;\nimport math;\n\nvoid main()\n{\n" ~
            "    writeln(doubleValue(6));\n}\n");
    }

    const saved = loadSettings();
    auto apiKey = environment.get("AURORA_PROBE_KEY");
    if (apiKey.length == 0) apiKey = saved.apiKey;
    if (apiKey.length == 0)
    {
        writeln("No configured API key; set AURORA_PROBE_KEY or save one in Aurora.");
        return 1;
    }
    const baseUrl = saved.baseUrl;
    auto client = new OpenCodeClient(baseUrl, apiKey);
    writeln("workspace = ", workspace);

    ChatRequestMessage[] messages;
    ChatRequestMessage system;
    system.role = "system";
    system.content = buildSystemPrompt(true, workspace, "Windows");
    messages ~= system;
    ChatRequestMessage user;
    user.role = "user";
    user.content = environment.get("AURORA_PROBE_TASK",
        complexScenario
        ? "Complete the task-store feature across this D project. Add " ~
          "`bool complete(string title)` to TaskStore: mark only the first " ~
          "pending exact-title match and return whether one changed. Add " ~
          "`Task[] pendingSorted() const` returning a copy of unfinished tasks " ~
          "ordered by descending priority, then ascending title, without " ~
          "reordering the store. Implement `formatPendingReport`: numbered " ~
          "lines exactly like `1. [5] Fix bug`, each ending in a newline, or " ~
          "`(none)\\n`. Update app.d to complete Write docs and print the " ~
          "report. Compile and run it, then answer concisely."
        : "Add `int clamp(int value, int minimum, int maximum)` to " ~
          "source/math.d. Update source/app.d to print " ~
          "clamp(doubleValue(6), 0, 10). Make the changes, compile and run the " ~
          "program, then answer concisely.");
    messages ~= user;

    auto tools = nativeOnlyToolDefinitions();
    StopWatch timer = StopWatch(AutoStart.yes);
    size_t toolRounds;
    size_t toolCalls;
    size_t mutationCalls;
    size_t nonProgressRounds;
    long completionTokens;
    long reasoningTokens;
    bool finished;
    string finalText;
    foreach (round; 0 .. 20)
    {
        auto body = client.buildBodyForTesting(messages,
            tools, saved.model, false);
        body = body.replace(`"stream":true`, `"stream":false`);
        write(bodyFile, body);
        const response = post(baseUrl ~ "/chat/completions", bodyFile,
            respFile, apiKey);
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
        if (("usage" in root.object) && root["usage"].type == JSONType.object)
        {
            auto usage = root["usage"];
            if (("completion_tokens" in usage.object) &&
                usage["completion_tokens"].type == JSONType.integer)
                completionTokens += usage["completion_tokens"].integer;
            if (("completion_tokens_details" in usage.object) &&
                usage["completion_tokens_details"].type == JSONType.object)
            {
                auto details = usage["completion_tokens_details"];
                if (("reasoning_tokens" in details.object) &&
                    details["reasoning_tokens"].type == JSONType.integer)
                    reasoningTokens += details["reasoning_tokens"].integer;
            }
        }
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
            finalText = content;
            finished = true;
            break;
        }
        ++toolRounds;
        toolCalls += calls.length;
        bool batchMutates;

        ChatRequestMessage assistant;
        assistant.role = "assistant";
        assistant.content = content;
        assistant.toolCalls = calls;
        messages ~= assistant;
        foreach (call; calls)
        {
            if (call.name == "edit" || call.name == "write" ||
                call.name == "apply_patch" || call.name == "remove")
            {
                ++mutationCalls;
                batchMutates = true;
            }
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
        if (batchMutates)
            nonProgressRounds = 0;
        else
            ++nonProgressRounds;
        if (nonProgressRounds >= 8)
        {
            writeln("FAIL: eight consecutive non-mutating rounds");
            return 5;
        }
    }
    timer.stop();
    writeln("FINAL: ", finalText.length > 0 ? finalText : "(empty)");
    writeln("METRICS: ", toolRounds, " tool rounds, ", toolCalls,
        " calls, ", mutationCalls, " mutations, ", completionTokens,
        " completion tokens (", reasoningTokens, " reasoning), ",
        timer.peek.total!"msecs", " ms");

    if (!finished)
    {
        writeln("FAIL: did not finish within the twenty-round hard ceiling");
        return 5;
    }
    if (mutationCalls == 0)
    {
        writeln("FAIL: the agent never made the requested change");
        return 6;
    }
    OpenCodeToolCall verify;
    verify.name = "run";
    if (complexScenario)
    {
        // This verifier is deliberately absent while the model works, so it
        // cannot simply read and mimic the assertions.
        write(buildPath(workspace, "verify.d"),
            "import std.stdio;\nimport report;\nimport task_store;\n\n" ~
            "void main()\n{\n    TaskStore store;\n" ~
            "    store.add(\"Zulu\", 2);\n    store.add(\"Alpha\", 5);\n" ~
            "    store.add(\"Beta\", 5);\n    store.add(\"Alpha\", 1);\n" ~
            "    assert(!store.complete(\"Missing\"));\n" ~
            "    assert(store.complete(\"Alpha\"));\n" ~
            "    auto pending = store.pendingSorted();\n" ~
            "    assert(pending.length == 3);\n" ~
            "    assert(pending[0].title == \"Beta\" && " ~
            "pending[1].title == \"Zulu\" && pending[2].title == \"Alpha\");\n" ~
            "    assert(store.all()[0].title == \"Zulu\");\n" ~
            "    assert(formatPendingReport(store) == " ~
            "\"1. [5] Beta\\n2. [2] Zulu\\n3. [1] Alpha\\n\");\n" ~
            "    TaskStore empty;\n" ~
            "    assert(formatPendingReport(empty) == \"(none)\\n\");\n" ~
            "    writeln(\"complex-ok\");\n}\n");
        verify.arguments = `{"program":"dmd","args":["-Isource","-i","-run","verify.d"],"workdir":"."}`;
    }
    else
    {
        const mathText = readText(buildPath(workspace, "source", "math.d"));
        const appText = readText(buildPath(workspace, "source", "app.d"));
        if (mathText.indexOf("int clamp(") < 0 ||
            appText.indexOf("clamp(doubleValue(6), 0, 10)") < 0)
        {
            writeln("FAIL: requested code was not present after the agent finished");
            return 7;
        }
        verify.arguments = `{"program":"dmd","args":["-Isource","-i","-run","source/app.d"],"workdir":"."}`;
    }
    const verification = executeTool(verify, workspace);
    const expectedOutput = complexScenario ? "complex-ok" : "10";
    if (verification.failed || verification.output.indexOf(expectedOutput) < 0)
    {
        writeln("FAIL: independent compile/run check: ", verification.output);
        return 8;
    }
    writeln("PASS: autonomous agent edited, verified, and stopped within budget");
    return 0;
}
