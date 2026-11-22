module aurorahost.console;

import std.stdio : stderr, stdout;

/// GUI launches have no inherited console handles on Windows. Diagnostics are
/// best-effort and must never turn a working host into an exited process.
void errLine(string text) nothrow
{
    try
    {
        stderr.writeln(text);
        stderr.flush();
    }
    catch (Throwable)
    {
    }
}

void outLine(string text) nothrow
{
    try
    {
        stdout.writeln(text);
        stdout.flush();
    }
    catch (Throwable)
    {
    }
}