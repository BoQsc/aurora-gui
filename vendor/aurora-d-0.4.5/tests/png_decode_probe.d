module tests.png_decode_probe;

import aurora;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln;

int main()
{
    foreach (path; [
        "docs/screenshots/demos-montage.png",
        "docs/screenshots/desktop-environment.png",
        "docs/screenshots/notepad.png",
        "resources/windows/windows_file_manager.png"
    ])
    {
        StopWatch sw;
        sw.start();
        try
        {
            auto img = loadPngImage(path);
            sw.stop();
            writeln(path, ": ", img.width(), "x", img.height(), " decode ", sw.peek().total!"msecs", " ms");
        }
        catch (Exception e)
        {
            writeln(path, ": ERROR ", e.msg);
        }
    }
    return 0;
}
