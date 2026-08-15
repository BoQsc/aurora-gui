module aurorastream.graphicscapturepreview;

/// Low-resolution live-preview reader for FFmpeg's Windows Graphics Capture
/// source. The broadcaster uses the same `gfxcapture` HWND source directly;
/// this separate 30 FPS preview stays small so monitoring does not add a
/// full-resolution CPU readback.

import std.format : format;
import std.process : Config, Pid, Redirect, kill, pipeProcess, wait;
import std.stdio : File;
import std.string : indexOf;

version (Windows)
{
    import core.sys.windows.windows : DWORD, PeekNamedPipe;
    import core.thread : Thread;
    import core.time : msecs;
    import std.algorithm.comparison : min;
}

void bgraToRgbaInPlace(ubyte[] pixels)
{
    for (size_t offset = 0; offset + 3 < pixels.length; offset += 4)
    {
        const blue = pixels[offset];
        pixels[offset] = pixels[offset + 2];
        pixels[offset + 2] = blue;
        pixels[offset + 3] = 0xff;
    }
}

string[] graphicsCapturePreviewArguments(string hwndText, int width, int height,
    int fps = 30)
{
    const source = format(
        "gfxcapture=hwnd=%s:capture_cursor=0:capture_border=0:" ~
        "display_border=0:max_framerate=%d:output_fmt=bgra:" ~
        "width=%d:height=%d:resize_mode=scale_aspect",
        hwndText, fps, width, height);
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "lavfi", "-i", source,
        "-vf", "hwdownload,format=bgra",
        "-an", "-pix_fmt", "bgra", "-f", "rawvideo", "pipe:1"
    ];
}

final class GraphicsCapturePreview
{
    private Pid _process;
    private File _stdout;
    private File _stderr;
    private bool _running;
    private string _window;
    private int _width;
    private int _height;
    private int _fps;
    private string _failure;

    ~this()
    {
        shutdown();
    }

    string failure() const
    {
        return _failure;
    }

    private bool start(string hwndText, int width, int height, int fps)
    {
        _failure = "";
        try
        {
            auto pipes = pipeProcess(graphicsCapturePreviewArguments(
                hwndText, width, height, fps),
                Redirect.stdout | Redirect.stderr,
                cast(const string[string]) null, Config.suppressConsole);
            _process = pipes.pid;
            _stdout = pipes.stdout;
            _stderr = pipes.stderr;
            _running = true;
            _window = hwndText.idup;
            _width = width;
            _height = height;
            _fps = fps;
            return true;
        }
        catch (Exception error)
        {
            _failure = "Could not start Windows Graphics Capture preview: " ~
                error.msg;
            shutdown();
            return false;
        }
    }

    private bool readExact(ubyte[] destination)
    {
        size_t offset;
        try
        {
            version (Windows)
            {
                // An active WGC stream stops producing bytes when its target
                // is minimized. Never leave Aurora's preview thread blocked
                // forever in rawRead: poll the anonymous pipe and return a
                // useful failure after a bounded interval. This also lets app
                // shutdown join the preview thread promptly.
                enum idlePollLimit = 250; // 250 * 10 ms = 2.5 seconds
                int idlePolls;
                while (offset < destination.length)
                {
                    DWORD available;
                    if (PeekNamedPipe(_stdout.windowsHandle, null, 0, null,
                        &available, null) == 0)
                    {
                        _failure = "Windows Graphics Capture preview pipe closed.";
                        return false;
                    }
                    if (available == 0)
                    {
                        if (++idlePolls >= idlePollLimit)
                        {
                            _failure = "Windows Graphics Capture preview timed out; " ~
                                "the selected window may be minimized or no longer updating.";
                            return false;
                        }
                        Thread.sleep(10.msecs);
                        continue;
                    }
                    idlePolls = 0;
                    const requested = min(cast(size_t) available,
                        destination.length - offset);
                    auto received = _stdout.rawRead(
                        destination[offset .. offset + requested]);
                    if (received.length == 0) return false;
                    offset += received.length;
                }
                return true;
            }
            else
            {
            while (offset < destination.length)
            {
                auto received = _stdout.rawRead(destination[offset .. $]);
                if (received.length == 0) return false;
                offset += received.length;
            }
            return true;
            }
        }
        catch (Exception error)
        {
            _failure = "Windows Graphics Capture preview read failed: " ~
                error.msg;
            return false;
        }
    }

    bool capture(string hwndText, int width, int height, int fps,
        ubyte[] bgra)
    {
        if (hwndText.length == 0 || width <= 0 || height <= 0 || fps <= 0 ||
            bgra.length < cast(size_t) width * height * 4)
            return false;
        if (_running && (_window != hwndText || _width != width ||
            _height != height || _fps != fps))
            shutdown();
        if (!_running && !start(hwndText, width, height, fps)) return false;
        if (readExact(bgra[0 .. cast(size_t) width * height * 4]))
        {
            bgraToRgbaInPlace(bgra[0 .. cast(size_t) width * height * 4]);
            return true;
        }

        if (_failure.length == 0)
            _failure = "Windows Graphics Capture preview ended before a complete frame arrived.";
        shutdown(false);
        return false;
    }

    void shutdown(bool clearFailure = true)
    {
        if (_running)
        {
            try kill(_process);
            catch (Exception) {}
            try wait(_process);
            catch (Exception) {}
        }
        _running = false;
        if (_stdout.isOpen)
        {
            try _stdout.close();
            catch (Exception) {}
        }
        if (_stderr.isOpen)
        {
            try _stderr.close();
            catch (Exception) {}
        }
        _stdout = File.init;
        _stderr = File.init;
        _window = "";
        _width = 0;
        _height = 0;
        _fps = 0;
        if (clearFailure) _failure = "";
    }
}

unittest
{
    const arguments = graphicsCapturePreviewArguments("1841952", 480, 270);
    assert(arguments[0] == "ffmpeg");
    assert(arguments[$ - 1] == "pipe:1");
    bool foundSource;
    foreach (argument; arguments)
        if (argument.indexOf("gfxcapture=hwnd=1841952") >= 0 &&
            argument.indexOf("width=480:height=270") >= 0 &&
            argument.indexOf("display_border=0") >= 0)
            foundSource = true;
    assert(foundSource);

    ubyte[] pixel = [1, 2, 3, 4];
    bgraToRgbaInPlace(pixel);
    assert(pixel == [3, 2, 1, 255]);
}
