module auroraopencode.checkrevision;

import std.algorithm : canFind;
import std.json : parseJSON, JSONType, JSONValue;
import std.regex : matchFirst;
import std.string : strip, split, indexOf;

private struct InlineCases
{
    string templateCommand;
    string[] inputs;
}

/// Recognize a small literal parameter table without evaluating checker source.
/// Unsupported syntax retains the existing exact-command identity rule.
private InlineCases inlineCases(string command)
{
    InlineCases result;
    try
    {
        const separator = command.indexOf('\n');
        if (separator < 0) return result;
        const program = command[0 .. separator];
        if (!["python", "python.exe", "python3", "python3.exe"].canFind(program)) return result;
        auto arguments = parseJSON(command[separator + 1 .. $]);
        if (arguments.type != JSONType.array) return result;
        size_t sourceIndex = size_t.max;
        foreach (i, arg; arguments.array)
            if (arg.type == JSONType.string && arg.str == "-c" && i + 1 < arguments.array.length)
            { sourceIndex = i + 1; break; }
        if (sourceIndex == size_t.max || arguments.array[sourceIndex].type != JSONType.string) return result;
        const source = arguments.array[sourceIndex].str;
        auto assignment = matchFirst(source, `(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*=[ \t]*(\[)`);
        if (!assignment.length) return result;
        const name = assignment[1];
        const begin = assignment.pre.length + assignment.hit.length - 1;
        size_t position = begin + 1, columns;
        string[] inputs;
        void space() { while (position < source.length && " \t\r\n".canFind(source[position])) ++position; }
        while (position < source.length)
        {
            space();
            if (position < source.length && source[position] == ']') break;
            if (position >= source.length || source[position++] != '(') return result;
            string[] values;
            while (position < source.length)
            {
                space();
                const start = position;
                if (position < source.length && (source[position] == '\'' || source[position] == '"'))
                {
                    const quote = source[position++];
                    while (position < source.length && source[position] != quote)
                    {
                        if (source[position] == '\\') return result;
                        ++position;
                    }
                    if (position == source.length) return result;
                    ++position;
                }
                else
                {
                    while (position < source.length && !",) \t\r\n".canFind(source[position])) ++position;
                    const scalar = source[start .. position];
                    if (!matchFirst(scalar, `^(?:[-+]?(?:\d+(?:\.\d*)?|\.\d+)|True|False|None)$`)) return result;
                }
                if (position == start) return result;
                values ~= source[start .. position];
                space();
                if (position >= source.length) return result;
                if (source[position] == ')') { ++position; break; }
                if (source[position++] != ',') return result;
            }
            if (values.length < 2 || (columns && values.length != columns)) return result;
            columns = values.length;
            inputs ~= JSONValue(values[0 .. $ - 1]).toString();
            space();
            if (position < source.length && source[position] == ',') { ++position; continue; }
            if (position >= source.length || source[position] != ']') return result;
        }
        if (!inputs.length || position >= source.length || source[position] != ']') return result;
        const end = position + 1;
        auto loop = matchFirst(source[end .. $], `(?m)^[ \t]*for[ \t]+([A-Za-z_][\w, \t]*)[ \t]+in[ \t]+` ~ name ~ `[ \t]*:`);
        if (!loop.length) return result;
        auto names = loop[1].split(',');
        if (names.length != columns || !["expected", "want"].canFind(names[$ - 1].strip())) return result;
        auto normalized = arguments.array.dup;
        normalized[sourceIndex] = JSONValue(source[0 .. begin] ~ "<retained-input-cases>" ~ source[end .. $]);
        result.templateCommand = program ~ "\n" ~ JSONValue(normalized).toString();
        result.inputs = inputs;
    }
    catch (Exception) {}
    return result;
}

/// A passing inline revision may correct expected values, just as editing a
/// generated test file can. Original input tuples, assertion logic, interpreter
/// arguments, imports and surrounding guards must all be retained.
bool retainsInlineCheckCoverage(string previous, string candidate)
{
    const old = inlineCases(previous), next = inlineCases(candidate);
    if (!old.templateCommand.length || old.templateCommand != next.templateCommand) return false;
    int[string] available;
    foreach (input; next.inputs) ++available[input];
    foreach (input; old.inputs)
    {
        auto count = input in available;
        if (count is null || *count <= 0) return false;
        --*count;
    }
    return true;
}
