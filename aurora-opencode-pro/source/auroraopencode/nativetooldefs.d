module auroraopencode.nativetooldefs;

import auroraopencode.core : OpenCodeToolDef;
import std.json : JSONType, parseJSON;

bool nativeOperationReadOnly(string name, string arguments)
{
    if (name == "environment") return true;
    if (name != "archive" && name != "data") return false;
    try
    {
        const args = parseJSON(arguments);
        if (args.type != JSONType.object) return false;
        auto action = "action" in args.object;
        if (action is null || action.type != JSONType.string) return false;
        return name == "archive" ? action.str == "list" || action.str == "validate" :
            action.str == "query" || action.str == "validate";
    }
    catch (Exception) return false;
}

OpenCodeToolDef archiveToolDefinition()
{
    return OpenCodeToolDef("archive",
        "Create, list, extract or validate ZIP and uncompressed TAR archives natively. " ~
        "Prefer this over packaging scripts. create takes paths relative to root (default workspace); " ~
        "output and extraction destination must be new. Extraction is staged and never overwrites existing files. " ~
        "List results are paged with offset/limit. ZIP input is memory-backed and capped at 512 MiB; " ~
        "use streaming TAR for larger inputs (up to 8 GiB). Links are not followed or extracted.",
        `{"type":"object","properties":{"action":{"type":"string","enum":["create","list","extract","validate"]},"path":{"type":"string","description":"Archive path ending in .zip or .tar"},"root":{"type":"string","description":"Base directory for create inputs"},"paths":{"type":"array","items":{"type":"string"},"description":"Files/directories to include, relative to root"},"destination":{"type":"string","description":"New directory for extract"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":200}},"required":["action","path"]}`);
}

OpenCodeToolDef dataToolDefinition()
{
    return OpenCodeToolDef("data",
        "Query, validate, format or atomically edit JSON/CSV files natively (up to 16 MiB). " ~
        "Use RFC 6901 pointers: /settings/timeout, /rows/0 or /2/1 for CSV (array of string rows, header included). " ~
        "set uses valueJson (a JSON-encoded string, parsed exactly once), adds an object key or appends with /-; remove deletes an existing value. " ~
        "Examples: valueJson=\"true\" sets a boolean; valueJson=\"[\\\"review.zip\\\",\\\"digest\\\"]\" appends a CSV row at /-. " ~
        "Batch changes apply together or leave the original intact. Existing parent paths are required. " ~
        "Query arrays with offset/limit. expectedSha256 optionally guards against stale edits. " ~
        "Edits reserialize the file; original whitespace is not preserved. JSON and CSV only.",
        `{"type":"object","properties":{"action":{"type":"string","enum":["query","validate","set","remove","format"]},"path":{"type":"string"},"format":{"type":"string","enum":["json","csv"]},"pointer":{"type":"string"},"valueJson":{"type":"string","description":"Replacement encoded as JSON text: true, 30, null, \"text\", an array or an object. Parsed once; strings require JSON quotes."},"changes":{"type":"array","maxItems":200,"items":{"type":"object","properties":{"action":{"type":"string","enum":["set","remove"]},"pointer":{"type":"string"},"valueJson":{"type":"string","description":"Replacement encoded as JSON text: true, 30, null, \"text\", an array or an object. Parsed once; strings require JSON quotes."}},"required":["pointer"]}},"expectedSha256":{"type":"string"},"delimiter":{"type":"string"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":200}},"required":["action","path"]}`);
}

OpenCodeToolDef environmentToolDefinition()
{
    return OpenCodeToolDef("environment",
        "Inspect the OS, current process/workspace, executable availability, disk capacity, " ~
        "processes or TCP listeners without shell commands. executables resolves supplied names " ~
        "without running them; use run with explicit --version arguments when a version is needed. " ~
        "Filter processes by name/pid, ports by port/pid. Results are bounded and report truncation. " ~
        "TCP listener inspection currently supports Windows. Environment variable values are not dumped.",
        `{"type":"object","properties":{"action":{"type":"string","enum":["system","executables","disk","processes","ports"]},"names":{"type":"array","maxItems":64,"items":{"type":"string"}},"path":{"type":"string"},"name":{"type":"string"},"pid":{"type":"integer","minimum":0},"port":{"type":"integer","minimum":0,"maximum":65535},"limit":{"type":"integer","minimum":1,"maximum":200}}}`);
}
