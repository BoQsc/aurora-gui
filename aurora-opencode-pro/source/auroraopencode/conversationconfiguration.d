module auroraopencode.conversationconfiguration;

import auroraopencode.core : OpenCodeToolDef;
import auroraopencode.requestpolicy : RequestPolicy;
import auroraopencode.turnpolicy : TurnPolicy;
import auroraopencode.projectioncache : ProjectionRevision;
import auroraopencode.developerpolicy : DeveloperToolPolicy;
import std.json : JSONValue, JSONType;
import std.traits : FieldNameTuple, isIntegral, isSomeString, isUnsigned;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

public struct ActorConfiguration
{
    string baseUrl, apiKey, workspace;
    string diagnosticModel;
    RequestPolicy request;
    TurnPolicy turn;
    bool recordTrace;
    bool quickTitle, modelCompaction;
    DeveloperToolPolicy developer;
    long outageBudgetMs = -1;
}

/// Connection credentials never enter a behavior command or trace identity.
public JSONValue actorBehaviorJson(const ref ActorConfiguration config)
{
    JSONValue value; value["workspace"] = config.workspace; value["outageBudgetMs"] = config.outageBudgetMs;
    value["quickTitle"] = config.quickTitle; value["modelCompaction"] = config.modelCompaction;
    value["diagnosticModel"] = config.diagnosticModel;
    value["developer"] = JSONValue.emptyObject;
    static foreach (name; FieldNameTuple!DeveloperToolPolicy) value["developer"][name] = __traits(getMember, config.developer, name);
    static foreach (member; ["request", "turn"])
    {{
        value[member] = JSONValue.emptyObject;
        static foreach (name; FieldNameTuple!(typeof(__traits(getMember, ActorConfiguration.init, member))))
        {{
            alias T = typeof(__traits(getMember, __traits(getMember, ActorConfiguration.init, member), name));
            const field = __traits(getMember, __traits(getMember, config, member), name);
            static if (is(T == bool) || isSomeString!T) value[member][name] = field;
            else static if (isIntegral!T) value[member][name] = cast(long) field;
            else static if (is(T == OpenCodeToolDef[]))
            {
                value[member][name] = JSONValue.emptyArray;
                foreach (tool; field) value[member][name].array ~= JSONValue([tool.name, tool.description, tool.parametersJson]);
            }
            else static if (is(T == ProjectionRevision))
                value[member][name] = JSONValue([cast(long) field.graph, cast(long) field.capabilities]);
            else static assert(false, "Unrecorded actor policy field: " ~ name);
        }}
    }}
    return value;
}

public string configurationKey(const ref ActorConfiguration config)
{ return sha256Of(actorBehaviorJson(config).toString()).toHexString().idup; }

public ActorConfiguration decodeActorBehavior(ActorConfiguration current, const ref JSONValue value)
{
    current.workspace = value["workspace"].str;
    current.quickTitle = value["quickTitle"].boolean; current.modelCompaction = value["modelCompaction"].boolean;
    current.diagnosticModel = value["diagnosticModel"].str;
    static foreach (name; FieldNameTuple!DeveloperToolPolicy)
    {
        static if (is(typeof(__traits(getMember, current.developer, name)) == bool))
            __traits(getMember, current.developer, name) = value["developer"][name].boolean;
        else __traits(getMember, current.developer, name) = value["developer"][name].str;
    }
    if (value["outageBudgetMs"].integer >= 0) current.outageBudgetMs = value["outageBudgetMs"].integer;
    static foreach (member; ["request", "turn"])
    {{
        const source = value[member];
        static foreach (name; FieldNameTuple!(typeof(__traits(getMember, ActorConfiguration.init, member))))
        {{
            alias T = typeof(__traits(getMember, __traits(getMember, ActorConfiguration.init, member), name));
            const field = source[name];
            static if (is(T == bool)) __traits(getMember, __traits(getMember, current, member), name) = field.boolean;
            else static if (isSomeString!T) __traits(getMember, __traits(getMember, current, member), name) = field.str;
            else static if (isIntegral!T)
            {
                static if (isUnsigned!T) if (field.integer < 0) throw new Exception("Negative configuration limit: " ~ name);
                __traits(getMember, __traits(getMember, current, member), name) = cast(T) field.integer;
            }
            else static if (is(T == OpenCodeToolDef[]))
            {
                OpenCodeToolDef[] tools;
                foreach (tool; field.array)
                {
                    if (tool.array.length != 3) throw new Exception("Invalid configured tool definition");
                    tools ~= OpenCodeToolDef(tool.array[0].str, tool.array[1].str, tool.array[2].str);
                }
                __traits(getMember, __traits(getMember, current, member), name) = tools;
            }
            else static if (is(T == ProjectionRevision))
            {
                if (field.array.length != 2 || field.array[0].integer < 0 || field.array[1].integer < 0)
                    throw new Exception("Invalid configured projection revision");
                __traits(getMember, __traits(getMember, current, member), name) =
                    ProjectionRevision(cast(ulong) field.array[0].integer, cast(ulong) field.array[1].integer);
            }
            else static assert(false, "Unrestored actor policy field: " ~ name);
        }}
    }}
    return current;
}
