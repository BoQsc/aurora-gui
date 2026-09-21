module auroraopencode.websearch;

// ===========================================================================
// EXPERIMENTAL: `websearch` - discover pages from a query.
//
// This is an isolated, opt-in experiment. Search (discovery) is kept separate
// from `webfetch` (retrieval of a URL you already know), mirroring upstream
// opencode's two-tool model.
//
// The entire feature lives in this file plus a few deliberately tiny,
// greppable hooks elsewhere (all tagged `experimental: websearch`):
//   * source/auroraopencode/tools.d       - import, toolset registration, dispatch
//   * source/auroraopencode/systemprompt.d - one steering sentence
//   * source/auroraopencode/appui.d        - UI titles/subtitle
//   * tests/tools_test.d                   - coverage
// To drop the feature: delete this file and delete the tagged hooks. Nothing
// else references it.
//
// Enabled by default so it can be tried immediately; set AURORA_WEBSEARCH to
// 0/off/false/no (or AURORA_WEBSEARCH=disabled) to turn it off without editing
// code. Provider: Exa (default) or Parallel, chosen with
// AURORA_WEBSEARCH_PROVIDER=exa|parallel.
//
// Both providers are called through their public MCP endpoint exactly the way
// upstream opencode does, so no API key is required. To use your own quota set
// EXA_API_KEY (Exa) or PARALLEL_API_KEY (Parallel).
// ===========================================================================

import auroraopencode.core : OpenCodeToolDef;
import std.algorithm : canFind, startsWith;
import std.array : appender;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : exists, readText, remove, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.process : Config, Pid, environment, kill, spawnProcess, waitTimeout;
import std.stdio : File, stdin;
import std.string : splitLines, strip, toLower;
import std.typecons : Tuple, tuple;
import core.time : MonoTime, msecs;

/// Env switch. Anything other than the values below leaves the tool enabled,
/// so an unset variable means "on".
private enum disableValues = ["0", "off", "false", "no", "disabled", "disable"];

/// Whether the experimental websearch tool is active. Read on every call so
/// tests (and a relaunch with a different environment) see the current value.
public bool experimentalWebSearchEnabled()
{
    const raw = strip(toLower(environment.get("AURORA_WEBSEARCH", "on")));
    if (raw.length == 0) return true;
    return !disableValues.canFind(raw);
}

/// Which search backend to use. Unknown values fall back to Exa.
private string webSearchProvider()
{
    return strip(toLower(environment.get("AURORA_WEBSEARCH_PROVIDER", "exa"))) ==
        "parallel" ? "parallel" : "exa";
}

/// Tool definitions to append to a toolset. Returns an empty array when the
/// experiment is disabled, so registration needs no conditional in the caller.
public OpenCodeToolDef[] experimentalWebSearchTools()
{
    if (!experimentalWebSearchEnabled()) return null;
    return [
        OpenCodeToolDef(
            "websearch",
            "Search the public web and return ranked results (title, URL, " ~
            "snippet) for a query. Use it to discover pages when you only have " ~
            "a query; use `webfetch` afterwards to read a chosen result URL. " ~
            "Requires no API key; results may be truncated.",
            `{"type":"object","properties":{"query":{"type":"string","description":"Search query"},"num_results":{"type":"integer","description":"Number of results to return (default 8)"},"type":{"type":"string","enum":["auto","fast","deep"],"description":"Search depth (default auto)"},"livecrawl":{"type":"string","enum":["fallback","preferred"],"description":"Live crawl mode when supported (default fallback)"}},"required":["query"]}`
        ),
    ];
}

/// Execute a `websearch` call. Returns (output, failed). Network work happens
/// here; everything else (registration, dispatch, UI) lives in the caller so
/// this module stays the single drop point.
public Tuple!(string, bool) experimentalWebSearchExecute(string args,
    string workspace)
{
    JSONValue value;
    try value = parseJSON(args);
    catch (Exception) value = JSONValue.init;

    string query;
    int numResults = 8;
    string searchType = "auto";
    string livecrawl = "fallback";
    if (value.type == JSONType.object)
    {
        if (auto field = "query" in value.object)
            if (field.type == JSONType.string)
                query = field.str;
        numResults = objectInt(value, "num_results", objectInt(value,
            "numResults", 8));
        if (auto field = "type" in value.object)
            if (field.type == JSONType.string)
                searchType = field.str;
        if (auto field = "livecrawl" in value.object)
            if (field.type == JSONType.string)
                livecrawl = field.str;
    }
    query = strip(query);
    if (query.length == 0)
        return tuple("Error: websearch requires a non-empty `query` argument.",
            true);

    if (numResults <= 0) numResults = 8;
    if (numResults > 25) numResults = 25;
    searchType = oneOf(searchType, ["auto", "fast", "deep"], "auto");
    livecrawl = oneOf(livecrawl, ["fallback", "preferred"], "fallback");

    const provider = webSearchProvider();
    string url;
    string body;
    string[] headers = ["Content-Type: application/json",
        "Accept: application/json, text/event-stream"];
    if (provider == "parallel")
    {
        url = "https://search.parallel.ai/mcp";
        auto key = nonEmpty(environment.get("PARALLEL_API_KEY", null));
        if (key.length > 0)
            headers ~= "Authorization: Bearer " ~ key;
        body = `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":` ~
            `{"name":"web_search","arguments":{"objective":` ~
            JSONValue(query).toString() ~ `,"search_queries":[` ~
            JSONValue(query).toString() ~ `]}}}`;
    }
    else
    {
        url = "https://mcp.exa.ai/mcp";
        auto key = nonEmpty(environment.get("EXA_API_KEY", null));
        if (key.length > 0)
            url ~= "?exaApiKey=" ~ key;
        body = `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":` ~
            `{"name":"web_search_exa","arguments":{"query":` ~
            JSONValue(query).toString() ~ `,"type":"` ~ searchType ~
            `","numResults":` ~ to!string(numResults) ~ `,"livecrawl":"` ~
            livecrawl ~ `"}}}`;
    }

    enum timeoutMs = 30_000;
    auto exchange = postJson(url, headers, body, workspace, timeoutMs);

    const text = extractSearchText(exchange[0]);
    if (strip(text).length > 0)
        return tuple(truncateSearch(text), exchange[1]);

    // Not an MCP payload (provider error page, empty body, ...). Surface the
    // raw response so the failure is diagnosable rather than silent.
    const raw = strip(exchange[0]);
    if (raw.length == 0)
        return tuple("Error: no response from the search provider.", true);
    return tuple(truncateSearch(raw), exchange[1]);
}

/// POST a JSON-RPC body with curl through the shared process pattern (no
/// shell, so the URL and body never need quoting). The body is staged in a
/// temp file and passed with `--data-binary @file`.
private Tuple!(string, bool) postJson(string url, string[] headers,
    string body, string workspace, int timeoutMs)
{
    const bodyPath = tempPath("aurora-websearch-", ".json");
    try write(bodyPath, body);
    catch (Exception error)
        return tuple("Error: could not stage search request: " ~ error.msg,
            true);
    scope (exit) collectRemove(bodyPath);

    version (Windows)
        auto argv = ["curl.exe"];
    else
        auto argv = ["curl"];
    argv ~= "-sS";
    argv ~= "-L";
    argv ~= "--max-time";
    argv ~= to!string((timeoutMs + 999) / 1000);
    foreach (header; headers)
    {
        argv ~= "-H";
        argv ~= header;
    }
    argv ~= "--data-binary";
    argv ~= "@" ~ bodyPath;
    argv ~= url;

    return runCurl(argv, workspace, timeoutMs + 10_000);
}

/// Run curl with stdout and stderr merged into a temp file. Mirrors the
/// timeout/poll loop used by the built-in tools, so a hung provider cannot
/// wedge the conversation.
private Tuple!(string, bool) runCurl(string[] argv, string workdir,
    int timeoutMs)
{
    const outPath = tempPath("aurora-websearch-out-", ".txt");
    File outFile;
    try outFile.open(outPath, "w");
    catch (Exception error)
        return tuple("Error: could not open output file: " ~ error.msg, true);

    Pid pid;
    try pid = spawnProcess(argv, stdin, outFile, outFile, null,
        Config.suppressConsole, workdir);
    catch (Exception error)
    {
        collectClose(outFile);
        collectRemove(outPath);
        return tuple("Error: could not start search request: " ~ error.msg,
            true);
    }

    auto stopwatch = StopWatch(AutoStart.yes);
    bool timedOut;
    int exitCode;
    while (true)
    {
        const waited = waitTimeout(pid, msecs(100));
        if (waited.terminated)
        {
            exitCode = waited.status;
            break;
        }
        if (stopwatch.peek > msecs(timeoutMs))
        {
            timedOut = true;
            break;
        }
    }
    if (timedOut)
    {
        try kill(pid);
        catch (Exception) {}
    }

    collectClose(outFile);
    string output;
    if (exists(outPath))
    {
        try output = readText(outPath);
        catch (Exception) output = "";
        collectRemove(outPath);
    }
    if (timedOut)
        return tuple("Error: search request timed out after " ~
            to!string(timeoutMs / 1000) ~ "s.", true);
    // curl prints the reason to stderr (merged into the body) on failure, so a
    // non-zero exit with a body is still reported as failed but keeps the text.
    return tuple(output, exitCode != 0);
}

/// Pull the human-readable text out of an MCP `tools/call` response. Handles
/// both a plain JSON body and the `text/event-stream` framing (one `data:`
/// line per event).
private string extractSearchText(string body)
{
    const trimmed = strip(body);
    if (trimmed.length == 0) return "";
    if (trimmed[0] == '{')
    {
        auto direct = payloadText(trimmed);
        if (direct.length > 0) return direct;
    }
    foreach (line; body.splitLines())
    {
        const candidate = strip(line);
        if (!candidate.startsWith("data:")) continue;
        auto data = strip(candidate[5 .. $]);
        if (data.length == 0 || data == "[DONE]") continue;
        auto text = payloadText(data);
        if (text.length > 0) return text;
    }
    return "";
}

/// Extract `result.content[].text` (joined) from one JSON-RPC message, or an
/// `error` message rendered as text. Returns "" when the shape does not match.
private string payloadText(string json)
{
    JSONValue value;
    try value = parseJSON(json);
    catch (Exception) return "";
    if (value.type != JSONType.object) return "";

    if (auto error = "error" in value.object)
    {
        auto detail = error.type == JSONType.object
            ? ("message" in error.object
                ? error.object["message"].toString() : error.toString())
            : error.toString();
        return "Search provider error: " ~ detail;
    }

    auto result = "result" in value.object;
    if (result is null || result.type != JSONType.object) return "";
    auto content = "content" in result.object;
    if (content is null || content.type != JSONType.array) return "";

    auto builder = appender!string();
    foreach (item; content.array)
    {
        if (item.type != JSONType.object) continue;
        auto text = "text" in item.object;
        if (text is null || text.type != JSONType.string) continue;
        if (builder.data.length > 0) builder.put("\n");
        builder.put(text.str);
    }
    return builder.data;
}

/// Keep the discovery payload small: the model can `webfetch` a result when it
/// wants the full page, so there is no reason to spend the whole context here.
private string truncateSearch(string text)
{
    enum cap = 12_000;
    if (text.length <= cap) return text;
    return text[0 .. cap] ~ "\n…(search results truncated)";
}

private int objectInt(in JSONValue obj, string key, int fallback)
{
    if (auto field = key in obj.object)
        if (field.type == JSONType.integer)
            return cast(int) field.integer;
    return fallback;
}

private string oneOf(string value, string[] allowed, string fallback)
{
    foreach (candidate; allowed)
        if (value == candidate) return value;
    return fallback;
}

private string nonEmpty(string value)
{
    return value is null ? null : (strip(value).length > 0 ? value : null);
}

private string tempPath(string prefix, string suffix)
{
    return buildNormalizedPath(buildPath(cast(string) tempDir(),
        prefix ~ to!string(cast(long) MonoTime.currTime.ticks) ~ suffix));
}

private void collectClose(File file)
{
    try file.close();
    catch (Exception) {}
}

private void collectRemove(string path)
{
    try remove(path);
    catch (Exception) {}
}
