module aurorarecorder.ffmpeg;

/**
 * Locates the external `ffmpeg.exe` this recorder pipes raw screen frames to.
 *
 * Search order:
 *   1. the `AURORA_RECORDER_FFMPEG` environment variable (an explicit path),
 *   2. `ffmpeg.exe` next to the recorder executable (a portable drop-in),
 *   3. `ffmpeg.exe` on `PATH` (the usual WinGet install location).
 *
 * Nothing here spawns a process; `aurorarecorder.encoder` owns the pipe.
 */

import std.file : exists;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : split, strip;

/// Environment variable that overrides every other lookup.
enum string ffmpegEnvironmentVariable = "AURORA_RECORDER_FFMPEG";

/**
 * Resolve `ffmpeg.exe`, or "" when no copy could be found.
 * `exeDirectory` is checked first and may be "" to skip the portable location.
 */
string findFfmpeg(string exeDirectory)
{
    const explicit = strip(environment.get(ffmpegEnvironmentVariable, ""));
    if (explicit.length > 0 && exists(explicit))
        return explicit;

    if (exeDirectory.length > 0)
    {
        const beside = buildPath(exeDirectory, "ffmpeg.exe");
        if (exists(beside))
            return beside;
    }

    foreach (entry; split(environment.get("PATH", ""), ";"))
    {
        auto dir = strip(entry);
        if (dir.length >= 2 && dir[0] == '"' && dir[$ - 1] == '"')
            dir = dir[1 .. $ - 1];
        if (dir.length == 0)
            continue;
        const candidate = buildPath(dir, "ffmpeg.exe");
        if (exists(candidate))
            return candidate;
    }
    return "";
}

/// Directory holding the running executable, or "" when unknown.
string executableDirectory(string executablePath)
{
    if (executablePath.length == 0)
        return "";
    return dirName(executablePath);
}
