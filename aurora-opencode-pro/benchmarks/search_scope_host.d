module search_scope_host;
import auroraopencode.tools : runFilesystemHelperMode, executeTool;
import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.sessionserver : runSessionServer;
import std.file : readText, write;
import std.path : buildPath, dirName;
import std.json : parseJSON, JSONValue;

int main(string[] args)
{
    const helper = runFilesystemHelperMode(args);
    if (helper >= 0) return helper;
    if (args.length >= 2 && args[1] == "--session-server") return runSessionServer(args[2 .. $]);
    assert(args.length == 5 && args[1] == "--probe");
    setOpencodeStateDirectoryForTesting(buildPath(dirName(args[2]), "probe-state"));
    JSONValue results = JSONValue.emptyArray;
    auto calls = parseJSON(readText(args[3]));
    foreach (item; calls.array)
    {
        const result = executeTool(OpenCodeToolCall("opening-search", item["name"].str, item["arguments"].str), args[2]);
        JSONValue row;
        row["arguments"] = item["arguments"];
        row["failed"] = result.failed; row["elapsedMs"] = result.elapsedMs; row["output"] = result.output;
        results.array ~= row;
        if (item["name"].str == "grep" && !result.failed)
        {
            try
            {
                auto output = parseJSON(result.output);
                if (output["status"].str == "scope_selection")
                {
                    const next = output["suggestedSearches"].array[0];
                    const scoped = executeTool(OpenCodeToolCall("scoped-search", "grep", next.toString()), args[2]);
                    JSONValue narrowed;
                    narrowed["arguments"] = next.toString(); narrowed["failed"] = scoped.failed;
                    narrowed["elapsedMs"] = scoped.elapsedMs; narrowed["output"] = scoped.output;
                    results.array ~= narrowed;
                }
            }
            catch (Exception) {} // ordinary grep text is not a discovery object
        }
    }
    write(args[4], results.toPrettyString());
    return 0;
}
