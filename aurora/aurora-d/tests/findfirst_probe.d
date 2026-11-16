module tests.findfirst_probe;

import core.sys.windows.windows;
import std.stdio : writeln;
import std.path : buildPath;
import std.utf : toUTF16;

int main()
{
    version (Windows)
    {
        foreach (base; [
            "C:\\Users\\Windows10_new\\Documents\\web_webserver",
            "C:\\Users\\Windows10_new\\Desktop",
            "C:\\Users\\Windows10_new\\Downloads",
            "C:\\Users\\Windows10_new\\Documents"
        ])
        {
            foreach (attempt; 0 .. 8)
            {
                WIN32_FIND_DATAW fd;
                auto wpat = (base ~ "\\*.*").toUTF16;
                auto h = FindFirstFileW(wpat.ptr, &fd);
                if (h is null || h == INVALID_HANDLE_VALUE)
                    writeln("[", base, "] attempt ", attempt, ": FAILED err=", GetLastError());
                else
                {
                    int count;
                    do
                    {
                        ++count;
                    } while (FindNextFileW(h, &fd));
                    FindClose(h);
                    writeln("[", base, "] attempt ", attempt, ": OK count=", count);
                }
            }
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
