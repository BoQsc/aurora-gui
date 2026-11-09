module auroraopencode.structureddata;

import auroraopencode.nativeio;
import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.exception : enforce;
import std.file : getSize, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : extension;
import std.string : indexOf, replace, split, toLower;

enum ulong structuredDataLimit = 16 * 1024 * 1024;

private JSONValue parseCsv(string text, char delimiter, NativeCancel cancelled)
{
    JSONValue rows = JSONValue.emptyArray;
    JSONValue row = JSONValue.emptyArray;
    auto cell = appender!string();
    bool quoted, closed, started;
    size_t width;
    void finishCell()
    {
        row.array ~= JSONValue(cell.data);
        cell = appender!string();
        closed = false; started = false;
    }
    void finishRow()
    {
        finishCell();
        if (!width) width = row.array.length;
        enforce(row.array.length == width, "CSV rows have inconsistent column counts.");
        rows.array ~= row;
        enforce(rows.array.length <= 100_000, "CSV exceeds 100000 rows.");
        row = JSONValue.emptyArray;
    }
    foreach (i, ch; text)
    {
        if ((i & 65535) == 0) checkNativeCancellation(cancelled);
        if (quoted)
        {
            if (ch == '"') { quoted = false; closed = true; }
            else cell.put(ch);
            continue;
        }
        if (closed && ch == '"') { cell.put('"'); quoted = true; closed = false; continue; }
        if (ch == delimiter) { finishCell(); continue; }
        if (ch == '\n') { finishRow(); continue; }
        if (ch == '\r')
        {
            enforce(i + 1 == text.length || text[i + 1] == '\n', "CSV uses an unsupported bare CR; use LF or CRLF.");
            continue;
        }
        enforce(!closed, "Unexpected character after a quoted CSV field.");
        if (ch == '"')
        {
            enforce(!started && cell.data.length == 0, "Quote inside an unquoted CSV field.");
            quoted = true; started = true;
        }
        else { cell.put(ch); started = true; }
    }
    enforce(!quoted, "Unterminated quoted CSV field.");
    if (started || closed || cell.data.length || row.array.length) finishRow();
    return rows;
}

private string serializeCsv(const ref JSONValue rows, char delimiter)
{
    enforce(rows.type == JSONType.array, "CSV document must be an array of row arrays.");
    auto output = appender!string();
    size_t width;
    foreach (row; rows.array)
    {
        enforce(row.type == JSONType.array, "CSV rows must be arrays.");
        if (!width) width = row.array.length;
        enforce(width && row.array.length == width, "CSV rows must have equal, non-zero column counts.");
        foreach (i, cell; row.array)
        {
            enforce(cell.type == JSONType.string, "CSV cells must be strings.");
            if (i) output.put(delimiter);
            if (cell.str.canFind(delimiter) || cell.str.canFind('"') || cell.str.canFind('\n') || cell.str.canFind('\r'))
                output.put("\"" ~ cell.str.replace("\"", "\"\"") ~ "\"");
            else output.put(cell.str);
        }
        output.put('\n');
    }
    return output.data;
}

private string[] pointerParts(string pointer)
{
    if (!pointer.length) return null;
    enforce(pointer[0] == '/', "pointer must be an RFC 6901 JSON pointer, e.g. /settings/timeout or /2/1.");
    auto parts = pointer[1 .. $].split('/');
    foreach (ref part; parts)
    {
        for (size_t i; i < part.length; ++i)
            if (part[i] == '~')
            {
                enforce(i + 1 < part.length && (part[i + 1] == '0' || part[i + 1] == '1'), "Invalid JSON pointer escape.");
                ++i;
            }
        part = part.replace("~1", "/").replace("~0", "~");
    }
    enforce(parts.length <= 64, "JSON pointer is too deep.");
    return parts;
}

private size_t arrayIndex(string text, size_t length, bool append)
{
    if (text == "-" && append) return length;
    enforce(text.length && (text.length == 1 || text[0] != '0'), "Invalid array index.");
    foreach (ch; text) enforce(ch >= '0' && ch <= '9', "Invalid array index.");
    const index = to!size_t(text);
    enforce(index < length || (append && index == length), "Array index is out of range.");
    return index;
}

private JSONValue queryPointer(ref JSONValue value, string[] parts)
{
    if (!parts.length) return value;
    if (value.type == JSONType.object)
    {
        auto field = parts[0] in value.object;
        enforce(field !is null, "JSON pointer key does not exist: " ~ parts[0]);
        return queryPointer(*field, parts[1 .. $]);
    }
    enforce(value.type == JSONType.array, "JSON pointer traverses a scalar.");
    return queryPointer(value.array[arrayIndex(parts[0], value.array.length, false)], parts[1 .. $]);
}

private void changePointer(ref JSONValue value, string[] parts, string action, JSONValue replacement)
{
    if (!parts.length)
    {
        enforce(action == "set", "Cannot remove the document root.");
        value = replacement;
        return;
    }
    const leaf = parts.length == 1;
    if (value.type == JSONType.object)
    {
        auto field = parts[0] in value.object;
        if (leaf && action == "set") value[parts[0]] = replacement;
        else
        {
            enforce(field !is null, "JSON pointer key does not exist: " ~ parts[0]);
            if (leaf) value.object.remove(parts[0]);
            else changePointer(*field, parts[1 .. $], action, replacement);
        }
        return;
    }
    enforce(value.type == JSONType.array, "JSON pointer traverses a scalar.");
    const index = arrayIndex(parts[0], value.array.length, leaf && action == "set");
    if (!leaf) changePointer(value.array[index], parts[1 .. $], action, replacement);
    else if (action == "set")
    {
        if (index == value.array.length) value.array ~= replacement;
        else value.array[index] = replacement;
    }
    else value.array = value.array[0 .. index] ~ value.array[index + 1 .. $];
}

private JSONValue replacementValue(const ref JSONValue args, string action)
{
    if (action != "set") return JSONValue(null);
    auto encoded = "valueJson" in args.object;
    auto value = "value" in args.object;
    enforce(encoded is null || value is null, "Supply valueJson or value, never both.");
    if (encoded !is null)
    {
        enforce(encoded.type == JSONType.string, "valueJson must be a JSON-encoded string.");
        return parseJSON(encoded.str, 128);
    }
    enforce(value !is null, "set requires valueJson, e.g. true, 30, \"text\", or [\"a\",\"b\"].");
    return *value;
}

JSONValue structuredDataOperation(string arguments, string workspace, NativeCancel cancelled = null)
{
    auto args = parseJSON(arguments);
    enforce(args.type == JSONType.object, "data requires an object.");
    const action = nativeString(args, "action");
    enforce(["query", "validate", "set", "remove", "format"].canFind(action), "action must be query, validate, set, remove or format.");
    const path = nativePath(nativeString(args, "path"), workspace);
    const format = nativeString(args, "format", extension(path).length ? extension(path)[1 .. $].toLower() : "json");
    enforce(format == "json" || format == "csv", "Supported structured data formats: json and csv.");
    enforce(getSize(path) <= structuredDataLimit, "Structured data file exceeds 16 MiB limit.");
    const original = readText(path);
    const digest = sha256Of(original).toHexString().idup.toLower();
    const expected = nativeString(args, "expectedSha256");
    enforce(!expected.length || expected.toLower() == digest, "File changed since the expected SHA-256; query the current file before editing.");
    const delimiterText = nativeString(args, "delimiter", ",");
    enforce(delimiterText.length == 1 && delimiterText[0] != '"' && delimiterText[0] != '\r' && delimiterText[0] != '\n', "delimiter must be one character other than quote/newline.");
    const delimiter = delimiterText[0];
    checkNativeCancellation(cancelled);
    auto document = format == "json" ? parseJSON(original, 128) : parseCsv(original, delimiter, cancelled);
    JSONValue result;
    result["path"] = path; result["format"] = format; result["sha256"] = digest;
    if (action == "validate") { result["valid"] = true; return result; }
    if (action == "query")
    {
        auto selected = queryPointer(document, pointerParts(nativeString(args, "pointer")));
        const offset = nativeInteger(args, "offset", 0), limit = nativeInteger(args, "limit", 100);
        enforce(offset >= 0 && limit >= 1 && limit <= 200, "offset must be non-negative; limit must be 1..200.");
        if (selected.type == JSONType.array)
        {
            const count = selected.array.length;
            const start = cast(size_t)(offset < count ? offset : count);
            const end = start + limit < count ? start + cast(size_t)limit : count;
            result["value"] = JSONValue(selected.array[start .. end]);
            result["count"] = count;
            result["nextOffset"] = end < count ? JSONValue(end) : JSONValue(null);
        }
        else result["value"] = selected;
        enforce(result.toString().length <= 24_000, "Query result exceeds 24 KiB; select a narrower pointer or smaller limit.");
        return result;
    }
    if (action == "set" || action == "remove")
    {
        auto changes = "changes" in args.object;
        if (changes !is null)
        {
            enforce(changes.type == JSONType.array && changes.array.length && changes.array.length <= 200, "changes must contain 1..200 edits.");
            foreach (change; changes.array)
            {
                enforce(change.type == JSONType.object, "Each change must be an object.");
                const operation = nativeString(change, "action", action);
                enforce(operation == "set" || operation == "remove", "Change action must be set or remove.");
                changePointer(document, pointerParts(nativeString(change, "pointer")), operation, replacementValue(change, operation));
            }
        }
        else
        {
            changePointer(document, pointerParts(nativeString(args, "pointer")), action, replacementValue(args, action));
        }
    }
    const encoded = format == "json" ? document.toPrettyString() ~ "\n" : serializeCsv(document, delimiter);
    enforce(encoded.length <= structuredDataLimit, "Updated data exceeds 16 MiB limit.");
    checkNativeCancellation(cancelled);
    enforce(readText(path) == original, "File changed during the operation; update was not written.");
    if (encoded != original) atomicNativeWrite(path, encoded);
    result["changed"] = encoded != original;
    result["sha256"] = sha256Of(encoded).toHexString().idup.toLower();
    result["bytes"] = encoded.length;
    return result;
}
