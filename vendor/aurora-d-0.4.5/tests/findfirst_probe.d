module tests.findfirst_probe;

import core.sys.windows.windows;
import std.stdio : writeln;
import std.path : buildPath;
import std.utf : toUTF16;

int main()
{
    version (Windows)
    {
        auto base = "C:\\Users\\Windows10_new\\Documents\\web_webserver";
        foreach (pat; [
            base ~ "\\*.*",
            "\\\\?\\" ~ base ~ "\\*.*"
        ])
        {
            WIN32_FIND_DATAW fd;
            auto wpat = pat.toUTF16;
            auto h = FindFirstFileW(wpat.ptr, &fd);
            if (h is null || h == INVALID_HANDLE_VALUE)
            {
                writeln("PATTERN [", pat, "] FAILED err=", GetLastError());
                continue;
            }
            int count;
            do
            {
                ++count;
            } while (FindNextFileW(h, &fd));
            FindClose(h);
            writeln("PATTERN [", pat, "] OK count=", count, " (incl . and ..)");
        }
    }
    return 0;
}

version (Windows)
string windowsName(const(wchar)[] buffer)
{
    import std.utf : toUTF8;
    size_t length;
    foreach (ch; buffer)
    {
        if (ch == 0) break;
        ++length;
    }
    return toUTF8(buffer[0 .. length]);
}
