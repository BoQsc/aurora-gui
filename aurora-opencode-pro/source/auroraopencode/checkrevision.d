module auroraopencode.checkrevision;

import std.algorithm : canFind;
import std.json : parseJSON, JSONType, JSONValue;
import std.regex : matchFirst;
import std.string : strip, split, indexOf, startsWith;

private struct InlineCases
{
    string templateCommand;
    string[] inputs;
}

private string equalityTemplate(string command)
{
    try
    {
        const separator = command.indexOf('\n');
        if (separator < 0 || !["python", "python.exe", "python3", "python3.exe"].canFind(command[0 .. separator])) return "";
        auto arguments = parseJSON(command[separator + 1 .. $]);
        if (arguments.type != JSONType.array) return "";
        foreach (i, value; arguments.array)
        {
            if (value.type != JSONType.string || value.str != "-c" || i + 1 == arguments.array.length ||
                arguments.array[i + 1].type != JSONType.string) continue;
            const source = arguments.array[i + 1].str;
            string normalized;
            bool found;
            foreach (line; source.split('\n'))
            {
                const stripped = line.strip();
                if (!stripped.startsWith("assert ")) { normalized ~= line ~ "\n"; continue; }
                size_t equal = size_t.max;
                int depth;
                char quote = 0;
                foreach (j; 0 .. line.length)
                {
                    const ch = line[j];
                    if (quote)
                    {
                        if (ch == quote && (j == 0 || line[j - 1] != '\\')) quote = 0;
                        continue;
                    }
                    if (ch == '\'' || ch == '"') quote = ch;
                    else if ("([{".canFind(ch)) ++depth;
                    else if (")]}".canFind(ch)) --depth;
                    else if (!depth && ch == '=' && j + 1 < line.length && line[j + 1] == '=')
                    { equal = j; break; }
                }
                if (equal == size_t.max) { normalized ~= line ~ "\n"; continue; }
                const right = line[equal + 2 .. $].strip();
                string kind;
                if (matchFirst(right, `^(?:[-+]?(?:\d+(?:\.\d*)?|\.\d+)|True|False|None)$`))
                    kind = ["True", "False"].canFind(right) ? "bool" : right == "None" ? "none" : "number";
                else
                {
                    size_t start;
                    if (right.length && (right[0] == 'b' || right[0] == 'B')) start = 1;
                    if (right.length < start + 2 || (right[start] != '\'' && right[start] != '"'))
                    { normalized ~= line ~ "\n"; continue; }
                    const delimiter = right[start];
                    size_t end = start + 1;
                    while (end < right.length)
                    {
                        if (right[end] == '\\') { end += 2; continue; }
                        if (right[end] == delimiter) break;
                        ++end;
                    }
                    if (end != right.length - 1) { normalized ~= line ~ "\n"; continue; }
                    kind = start ? "bytes" : "string";
                }
                found = true;
                normalized ~= line[0 .. equal + 2] ~ "<expected:" ~ kind ~ ">\n";
            }
            if (!found) return "";
            auto args = arguments.array.dup; args[i + 1] = JSONValue(normalized);
            return command[0 .. separator] ~ "\n" ~ JSONValue(args).toString();
        }
    }
    catch (Exception) {}
    return "";
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
        auto assignment = matchFirst(source, `(?:^|[;\n])[ \t]*([A-Za-z_]\w*)[ \t]*=[ \t]*(\[)`);
        if (!assignment.length) return result;
        const name = assignment[1];
        const begin = assignment.pre.length + assignment.hit.length - 1;
        size_t position = begin + 1, columns;
        string[] inputs;
        void space() { while (position < source.length && " \t\r\n".canFind(source[position])) ++position; }
        string literal(size_t depth = 0)
        {
            if (depth > 16) return "";
            space();
            if (position >= source.length) return "";
            if (source[position] == '(' || source[position] == '[')
            {
                const open = source[position++], close = open == '(' ? ')' : ']';
                string value = [open];
                space();
                while (position < source.length && source[position] != close)
                {
                    const item = literal(depth + 1);
                    if (!item.length) return "";
                    value ~= item; space();
                    if (position < source.length && source[position] == ',')
                    { value ~= ','; ++position; space(); }
                    else if (position >= source.length || source[position] != close) return "";
                }
                if (position >= source.length) return "";
                ++position; return value ~ close;
            }
            const start = position;
            if (source[position] == '\'' || source[position] == '"')
            {
                const quote = source[position++];
                while (position < source.length && source[position] != quote)
                {
                    if (source[position] == '\\') return "";
                    ++position;
                }
                if (position == source.length) return "";
                ++position;
            }
            else
            {
                while (position < source.length && !",)] \t\r\n".canFind(source[position])) ++position;
                if (!matchFirst(source[start .. position], `^(?:[-+]?(?:\d+(?:\.\d*)?|\.\d+)|True|False|None)$`)) return "";
            }
            return source[start .. position];
        }
        while (position < source.length)
        {
            space();
            if (position < source.length && source[position] == ']') break;
            if (position >= source.length || source[position++] != '(') return result;
            string[] values;
            while (position < source.length)
            {
                space();
                const value = literal();
                if (!value.length) return result;
                values ~= value;
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
        auto loop = matchFirst(source[end .. $], `\bfor[ \t]+([A-Za-z_][\w, \t]*)[ \t]+in[ \t]+` ~ name ~ `\b`);
        if (!loop.length) return result;
        auto names = loop[1].split(',');
        if (names.length != columns || !["expected", "want", "e"].canFind(names[$ - 1].strip())) return result;
        if (names[$ - 1].strip() == "e" &&
            !matchFirst(source[end .. $], `(?:==[ \t]*e\b|isclose\([^;\n]*,[ \t]*e\b)`)) return result;
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
    const oldEquality = equalityTemplate(previous);
    if (oldEquality.length && oldEquality == equalityTemplate(candidate)) return true;
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
