module aurora.platform.select;

public import aurora.platform.base : NativeWindow, NativeWindowSink, WindowOptions;

version (AuroraHeadless)
{
    public import aurora.platform.headless : PlatformWindow;
}
else version (Windows)
{
    public import aurora.platform.win32 : PlatformWindow;
}
else version (OSX)
{
    public import aurora.platform.cocoa : PlatformWindow;
}
else version (linux)
{
    public import aurora.platform.x11 : PlatformWindow;
}
else
{
    static assert(0, "Aurora currently supports Windows, macOS, Linux/X11, or AuroraHeadless.");
}
