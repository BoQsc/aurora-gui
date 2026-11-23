module cli_main;

import aurorahost.control_client : ControlClient;
import std.array : join;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.stdio : stderr, stdout, writeln;
import std.string : replace;

private void usage()
{
    stdout.writeln("usage: aurora-opencode-lite-v2-cli [--port N] <command>");
    stdout.writeln("  list");
    stdout.writeln("  ping");
    stdout.writeln("  status");
    stdout.writeln("  send <text>");
    stdout.writeln("  clear");
    stdout.writeln("  retry");
    stdout.writeln("  get <node>");
    stdout.writeln("  set <node> <text>");
    stdout.writeln("  trigger <node> <action>");
}

private string flat(string text)
{
    return text.replace("\r", " ").replace("\n", " ");
}

version (HostCli)
int main(string[] args)
{
    ushort port = 8792;
    string[] command;
    for (size_t index = 1; index < args.length; ++index)
    {
        if (args[index] == "--port" && index + 1 < args.length)
        {
            port = to!ushort(args[index + 1]);
            ++index;
        }
        else
            command ~= args[index];
    }
    if (command.length == 0 || command[0] == "help" || command[0] == "--help")
    {
        usage();
        return command.length == 0 ? 2 : 0;
    }

    try
    {
        auto client = new ControlClient(port);
        scope (exit)
            client.close();
        switch (command[0])
        {
            case "list":
            case "tree":
            {
                const result = client.request("tree");
                foreach (node; result["nodes"].array)
                {
                    const text = node["text"].type == JSONType.string
                        ? flat(node["text"].str) : "";
                    stdout.writeln(node["id"].str, "\t", node["type"].str,
                        "\t", text);
                }
                return 0;
            }
            case "ping":
                client.request("ping");
                stdout.writeln("ok");
                return 0;
            case "status":
            {
                const result = client.request("tree");
                JSONValue[string] nodes;
                foreach (node; result["nodes"].array)
                    nodes[node["id"].str] = node;
                foreach (id; ["lite-status", "lite-session", "lite-base",
                              "lite-model", "lite-key-state", "lite-input"])
                {
                    if (id in nodes)
                    {
                        const value = "text" in nodes[id].object;
                        const text = value !is null &&
                            value.type == JSONType.string ? value.str : "";
                        stdout.writeln(id, "\t", flat(text));
                    }
                }
                return 0;
            }
            case "send":
                if (command.length < 2)
                    throw new Exception("send requires text");
                client.request("setText",
                    ["node": "lite-input", "text": command[1]]);
                client.request("trigger",
                    ["node": "lite-send", "action": "send"]);
                stdout.writeln("ok");
                return 0;
            case "clear":
                client.request("trigger",
                    ["node": "lite-clear", "action": "clear"]);
                stdout.writeln("ok");
                return 0;
            case "retry":
                client.request("trigger",
                    ["node": "lite-retry", "action": "retry"]);
                stdout.writeln("ok");
                return 0;
            case "get":
                if (command.length < 2)
                    throw new Exception("get requires a node id");
                stdout.writeln(client.request("getText",
                    ["node": command[1]])["text"].get!string);
                return 0;
            case "set":
                if (command.length < 3)
                    throw new Exception("set requires a node id and text");
                client.request("setText",
                    ["node": command[1], "text": command[2]]);
                stdout.writeln("ok");
                return 0;
            case "trigger":
                if (command.length < 3)
                    throw new Exception(
                        "trigger requires a node id and action");
                client.request("trigger",
                    ["node": command[1], "action": command[2]]);
                stdout.writeln("ok");
                return 0;
            default:
                throw new Exception("unknown command: " ~ command[0]);
        }
    }
    catch (Exception error)
    {
        stderr.writeln("cli: " ~ error.msg);
        return 1;
    }
}