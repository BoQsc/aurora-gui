module session_server_contracts;

import auroraopencode.sessionserver : SessionServerCommand,
    SessionServerCommandType, parseSessionServerCommand;
import std.stdio : writeln;
import std.string : startsWith;

int main()
{
    SessionServerCommand command;
    string error;

    assert(parseSessionServerCommand(
        `{"type":"create","id":"guide","title":"Town guide","model":"fast",` ~
        `"thinking":true,"tools":false,"instructions":"Stay in character.",` ~
        `"workspace":"C:/world"}`, command, error),
        "create must parse");
    assert(command.type == SessionServerCommandType.create);
    assert(command.id == "guide");
    assert(command.title == "Town guide");
    assert(command.model == "fast");
    assert(command.thinkingMode == 1, "explicit thinking flag");
    assert(command.toolsMode == 0, "explicit tools flag");
    assert(command.instructions == "Stay in character.");
    assert(command.workspace == "C:/world");
    assert(error.length == 0);

    assert(parseSessionServerCommand(
        `{"type":"create","id":"inherited"}`, command, error));
    assert(command.thinkingMode == -1, "missing thinking inherits app setting");
    assert(command.toolsMode == -1, "missing tools inherits app setting");

    assert(parseSessionServerCommand(
        `{"type":"create","tools":true,"toolsMode":0}`, command, error));
    assert(command.toolsMode == 0, "toolsMode must win over tools");

    assert(parseSessionServerCommand(
        `{"type":"submit","id":"guide","requestId":"r-1",` ~
        `"text":"Where is the inn?"}`, command, error));
    assert(command.type == SessionServerCommandType.submit);
    assert(command.id == "guide");
    assert(command.requestId == "r-1");
    assert(command.text == "Where is the inn?");

    assert(parseSessionServerCommand(`{"type":"cancel","id":"guide"}`,
        command, error));
    assert(command.type == SessionServerCommandType.cancel);
    assert(command.id == "guide");

    assert(parseSessionServerCommand(`{"type":"list"}`, command, error));
    assert(command.type == SessionServerCommandType.list);

    assert(parseSessionServerCommand(`{"type":"close","id":"guide"}`,
        command, error));
    assert(command.type == SessionServerCommandType.close);

    assert(parseSessionServerCommand(`{"type":"ping"}`, command, error));
    assert(command.type == SessionServerCommandType.ping);

    assert(parseSessionServerCommand(`{"type":"shutdown"}`, command, error));
    assert(command.type == SessionServerCommandType.shutdown);

    assert(!parseSessionServerCommand(`{"type":`, command, error));
    assert(error.startsWith("invalid_json"), error);

    assert(!parseSessionServerCommand(`[]`, command, error));
    assert(error == "invalid_json: expected an object", error);

    assert(!parseSessionServerCommand(`{"id":"guide"}`, command, error));
    assert(error == "missing_type", error);

    assert(!parseSessionServerCommand(`{"type":"submit","id":"guide"}`,
        command, error));
    assert(error == "missing_text", error);

    assert(!parseSessionServerCommand(`{"type":"submit","text":"hi"}`,
        command, error));
    assert(error == "missing_id", error);

    assert(!parseSessionServerCommand(`{"type":"cancel"}`, command, error));
    assert(error == "missing_id", error);

    assert(!parseSessionServerCommand(`{"type":"close"}`, command, error));
    assert(error == "missing_id", error);

    assert(!parseSessionServerCommand(`{"type":"explode"}`, command, error));
    assert(error == "unknown_command: explode", error);

    writeln("PASS session server: create/submit/cancel/list/close/ping/shutdown parsing");
    return 0;
}
