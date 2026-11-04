module dshell_timeout_contracts;

import auroraopencode.core : OpenCodeToolDef;
import auroraopencode.tools : builtinToolDefinitions, nativeOnlyToolDefinitions;
import std.json : parseJSON;
import std.stdio : writeln;

private void checkDshellTimeout(OpenCodeToolDef[] definitions, string setName)
{
    bool found;
    foreach (definition; definitions)
        if (definition.name == "dshell")
        {
            found = true;
            auto schema = parseJSON(definition.parametersJson);
            assert(schema["type"].str == "object");
            auto properties = schema["properties"];
            assert("timeout" in properties.object, setName ~ " dshell schema is missing timeout");
            auto timeout = properties["timeout"];
            assert(timeout["type"].str == "integer");
            assert(timeout["minimum"].integer == 100);
            assert(timeout["maximum"].integer == 600000);
            assert(timeout["description"].str.length > 0);
        }
    assert(found, setName ~ " dshell definition is missing");
}

int main()
{
    checkDshellTimeout(nativeOnlyToolDefinitions(), "native-only");
    checkDshellTimeout(builtinToolDefinitions(), "builtin");
    writeln("PASS dshell schema exposes timeout 100..600000 in native-only and builtin tool sets");
    return 0;
}
