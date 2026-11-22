module aurorahost.controller_supervisor;

import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.process : Config, spawnProcess, wait;

/**
 * Restart an app-provided controller executable without restarting the host
 * window. The app supplies the executable and port; this module owns only the
 * generic launch/wait/retry lifecycle and is safe to use from any host app.
 */
final class ControllerSupervisor
{
    private string _executable;
    private ushort _port;
    private uint _maxLaunches;
    private uint _retryDelayMs;
    private void delegate(string) _log;
    private Thread _thread;
    private bool _stopped;

    this(string executable, ushort port, uint maxLaunches = 10,
        uint retryDelayMs = 500, void delegate(string) log = null)
    {
        _executable = executable;
        _port = port;
        _maxLaunches = maxLaunches;
        _retryDelayMs = retryDelayMs;
        _log = log;
    }

    void start()
    {
        if (_thread !is null)
            return;
        _thread = new Thread(&run);
        _thread.isDaemon = true;
        _thread.start();
    }

    void stop()
    {
        _stopped = true;
    }

    private void run()
    {
        // Let the host control listener bind before the first connection.
        Thread.sleep(_retryDelayMs.msecs);
        for (uint attempt = 0; attempt < _maxLaunches && !_stopped; ++attempt)
        {
            try
            {
                auto pid = spawnProcess(
                    [_executable, "--port", to!string(_port)],
                    null, Config.suppressConsole);
                const code = wait(pid);
                if (_stopped)
                    break;
                report("controller exited (" ~ to!string(code) ~
                    "); restarting");
            }
            catch (Exception error)
            {
                if (_stopped)
                    break;
                report("could not launch controller: " ~ error.msg);
            }
            if (!_stopped)
                Thread.sleep(_retryDelayMs.msecs);
        }
        if (!_stopped)
            report("controller supervisor stopped after repeated exits");
    }

    private void report(string text)
    {
        if (_log !is null)
            _log(text);
    }
}