// SPDX-License-Identifier: 0BSD
/**
 * Runtime probe for the msvcrt compatibility layer.
 *
 * The edge-test driver builds this with the host's CRT flags and passes a
 * Unicode argument and environment value.  It distinguishes failures with
 * exit codes so a broken argv/environment/time shim is diagnosable.
 */
module crt_probe;

import experiment.aurorahost.crt.msvcrt_shim;
import core.stdc.stdlib : getenv;
import core.stdc.string : strlen;
import std.stdio : writeln;

extern(C) long time(long* result);

private enum minimumTimestamp = 1_600_000_000L;

int main(string[] args)
{
    if (args.length != 2)
    {
        writeln("probe: expected one Unicode argument");
        return 2;
    }

    const value = getenv("AURORA_CRT_UNICODE");
    if (value is null)
    {
        writeln("probe: Unicode environment value is missing");
        return 3;
    }

    const environmentValue = value[0 .. strlen(value)];
    if (environmentValue != args[1])
    {
        writeln("probe: environment value does not match argv");
        writeln("argv: ", args[1]);
        writeln("env:  ", environmentValue);
        return 4;
    }

    const now = time(null);
    if (now < minimumTimestamp)
    {
        writeln("probe: time returned an implausible value");
        return 5;
    }

    writeln("CRT probe passed");
    return 0;
}
