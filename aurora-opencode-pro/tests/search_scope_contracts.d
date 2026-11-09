module search_scope_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : executeTool;
import auroraopencode.searchscope : discoverProjectScopes;
import std.file : mkdirRecurse, write;
import std.path : absolutePath, buildPath;
import std.string : indexOf;
import std.array : replicate;
import std.json : parseJSON;
import std.conv : to;
import std.stdio : writeln;
import core.time : MonoTime, seconds;

int main()
{
    const root = absolutePath("search-scope-" ~ to!string(MonoTime.currTime.ticks));
    const host = buildPath(root, "experiments", "example-host");
    const companion = buildPath(root, "experiments", "example-host-editor");
    mkdirRecurse(buildPath(host, "source")); mkdirRecurse(companion);
    mkdirRecurse(buildPath(root, "artifacts"));
    mkdirRecurse(buildPath(root, "other", "src"));
    setOpencodeStateDirectoryForTesting(buildPath(root, ".state"));
    write(buildPath(host, "dub.json"), `{"name":"example-host"}`);
    write(buildPath(companion, "package.json"), `{"name":"example-host-editor"}`);
    write(buildPath(host, "source", "main.d"), "module examplehost; // real_source_marker\n");
    write(buildPath(root, "other", "src", "reference.d"), "import examplehost;\n");
    write(buildPath(root, "artifacts", "audit.txt"), "examplehost generated_only_marker\n");
    const found = discoverProjectScopes(root, "examplehost");
    assert(found.length == 2 && found[0] == host);
    assert(discoverProjectScopes(root, "example.?host")[0] == host);
    const clock = MonoTime.currTime;
    auto discovery = executeTool(OpenCodeToolCall("auto", "grep",
        `{"pattern":"examplehost","mode":"files","timeout":120000}`), root);
    assert(!discovery.failed, discovery.output);
    auto result = parseJSON(discovery.output);
    assert(result["status"].str == "scope_selection" && !result["contentsSearched"].boolean);
    assert(result["suggestedSearches"].array[0]["path"].str == host);
    assert(!("timeout" in result["suggestedSearches"].array[0].object));
    assert(MonoTime.currTime - clock < 5.seconds, "Project discovery became a content scan");
    auto wildcard = executeTool(OpenCodeToolCall("wildcard", "grep",
        `{"pattern":"examplehost","include":"*","timeout":120000}`), root);
    assert(!wildcard.failed && parseJSON(wildcard.output)["status"].str == "scope_selection");
    auto selected = executeTool(OpenCodeToolCall("selected", "grep", result["suggestedSearches"].array[0].toString()), root);
    assert(!selected.failed && selected.output.indexOf("main.d") >= 0 && selected.output.indexOf("audit.txt") < 0);
    auto complete = executeTool(OpenCodeToolCall("all", "grep",
        `{"pattern":"examplehost","scope":"contents","mode":"files"}`), root);
    assert(!complete.failed && complete.output.indexOf("reference.d") >= 0 && complete.output.indexOf("audit.txt") < 0);
    auto alternatives = executeTool(OpenCodeToolCall("alternatives", "grep",
        `{"pattern":"real_source_marker","scope":"contents","include":"*.{d,md}"}`), root);
    assert(!alternatives.failed && alternatives.output.indexOf("main.d") >= 0, alternatives.output);
    auto generated = executeTool(OpenCodeToolCall("generated", "grep",
        `{"pattern":"generated_only_marker","scope":"contents","includeGenerated":true}`), root);
    assert(!generated.failed && generated.output.indexOf("audit.txt") >= 0);
    auto explicitGenerated = executeTool(OpenCodeToolCall("explicit", "grep",
        `{"pattern":"generated_only_marker","path":"artifacts"}`), root);
    assert(!explicitGenerated.failed && explicitGenerated.output.indexOf("audit.txt") >= 0);
    writeln("PASS project discovery, ranked scopes, explicit cross-project search and generated-file opt-in");
    foreach (i; 0 .. 60)
        write(buildPath(host, "source", "large" ~ to!string(i) ~ ".d"), "not_the_query 1234567890\n".replicate(12000));
    auto timed = executeTool(OpenCodeToolCall("deadline", "grep",
        `{"pattern":"no_such_match","path":"experiments/example-host","timeout":1}`), root);
    assert(timed.failed, timed.output);
    assert(timed.output.indexOf("Suggested narrower search:") >= 0, timed.output);
    assert(timed.output.indexOf("larger `timeout`") < 0 && timed.output.indexOf("Increasing the deadline alone") >= 0);
    writeln("PASS timeout recovery emits narrower arguments without deadline escalation");
    return 0;
}
