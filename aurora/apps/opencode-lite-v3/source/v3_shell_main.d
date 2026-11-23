module v3_shell_main;

import core.sys.windows.windows : GetCurrentProcessId;
import opencodev3.controller : V3Controller;
import opencodev3.session : SessionStore;
import std.array : replace;
import std.process : spawnProcess, wait;
import std.stdio : readln, stdout, writeln;
import std.string : indexOf, startsWith, strip;

int main()
{
    auto sessions = new SessionStore();
    auto controller = new V3Controller();
    writeln("READY pid=", GetCurrentProcessId());
    stdout.flush();
    while (true)
    {
        auto line = readln();
        if (!line.length)
            break;
        line = line.strip;
        if (line == "quit")
            break;
        if (line == "pid")
        {
            writeln("PID ", GetCurrentProcessId());
            stdout.flush();
            continue;
        }
        if (line == "sessions list")
        {
            foreach (entry; sessions.list())
                writeln(entry);
            stdout.flush();
            continue;
        }
        if (line.startsWith("send "))
        {
            controller.send(line[5 .. $].strip);
            writeln("STATUS ", controller.status());
            stdout.flush();
            continue;
        }
        if (line == "tick")
        {
            controller.service();
            writeln("STATUS ", controller.status());
            stdout.flush();
            continue;
        }
        if (line == "stop")
        {
            controller.stop();
            writeln("STATUS ", controller.status());
            stdout.flush();
            continue;
        }
        if (line == "retry")
        {
            controller.retry();
            writeln("STATUS ", controller.status());
            stdout.flush();
            continue;
        }
        if (line == "chat status")
        {
            writeln("STATUS ", controller.status());
            writeln("TRANSCRIPT ", controller.transcript().replace("\n", " | "));
            stdout.flush();
            continue;
        }
        if (line.startsWith("sessions new "))
        {
            const name = line[13 .. $].strip;
            writeln("ACTIVE ", sessions.create(name));
            stdout.flush();
            continue;
        }
        if (line.startsWith("sessions use "))
        {
            const id = line[13 .. $].strip;
            writeln(sessions.use(id) ? "OK" : "ERROR unknown session");
            stdout.flush();
            continue;
        }
        if (line.startsWith("sessions rename "))
        {
            const rest = line[16 .. $].strip;
            const split = rest.indexOf(' ');
            if (split < 0)
                writeln("ERROR usage: sessions rename <id> <name>");
            else
                writeln(sessions.rename(rest[0 .. split],
                    rest[split + 1 .. $]) ? "OK" : "ERROR unknown session");
            stdout.flush();
            continue;
        }
        if (line.startsWith("sessions delete "))
        {
            const id = line[16 .. $].strip;
            writeln(sessions.remove(id) ? "OK" : "ERROR unknown session");
            stdout.flush();
            continue;
        }
        if (line.startsWith("load ") || line.startsWith("reload "))
        {
            const path = line[line.indexOf(' ') + 1 .. $].strip;
            try
            {
                writeln("LOADING ", path);
                const code = wait(spawnProcess([path]));
                writeln("LOADED ", path, " EXIT ", code);
            }
            catch (Exception error)
            {
                writeln("ERROR ", error.msg);
            }
            stdout.flush();
            continue;
        }
        writeln("UNKNOWN ", line);
        stdout.flush();
    }
    return 0;
}
