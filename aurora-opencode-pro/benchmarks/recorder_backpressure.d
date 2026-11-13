module recorder_backpressure;
import std.process;
import std.stdio;
import core.thread : Thread;
import core.time : msecs;
import core.sys.windows.windows;

/// Real FFmpeg with a one-second encoder stall. The recorder's actual pipe
/// blocks, exercising missed capture ticks rather than a simulated frame loop.
int main(string[] args)
{
    auto child=spawnProcess([environment["AURORA_TEST_REAL_FFMPEG"]]~args[1..$],stdin,stdout,stderr);
    Thread.sleep(700.msecs);
    auto process=OpenProcess(0x0800,FALSE,cast(DWORD)child.processID);
    if(process !is null)
    {
        auto library=LoadLibraryW("ntdll.dll"w.ptr);
        alias Suspend=extern(Windows) int function(HANDLE);
        auto suspend=cast(Suspend)GetProcAddress(library,"NtSuspendProcess");
        auto resume=cast(Suspend)GetProcAddress(library,"NtResumeProcess");
        if(suspend !is null && resume !is null)
        { suspend(process);Thread.sleep(1000.msecs);resume(process); }
        CloseHandle(process);
    }
    return wait(child);
}
