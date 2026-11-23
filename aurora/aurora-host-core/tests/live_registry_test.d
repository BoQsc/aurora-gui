module live_registry_test;

import aurorahost.live_registry : isLive;
import aurorahost.single_instance : HostInstance;
import core.sys.windows.windows : GetCurrentProcessId;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    const key = "enforcement-test-" ~ to!string(GetCurrentProcessId());
    HostInstance instance;
    if (!instance.acquire(key))
    {
        writeln("FAIL acquire");
        return 1;
    }
    if (!isLive(key))
    {
        writeln("FAIL live registration");
        instance.release();
        return 2;
    }
    if (!instance.owned())
    {
        writeln("FAIL ownership");
        instance.release();
        return 3;
    }
    instance.release();
    if (isLive(key))
    {
        writeln("FAIL stale registration");
        return 4;
    }
    writeln("host-core enforcement passed: live registration acquire/release");
    return 0;
}
