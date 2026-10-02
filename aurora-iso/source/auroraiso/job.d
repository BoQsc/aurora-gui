/**
 * A tiny background-job helper: runs a delegate on its own thread and exposes
 * progress, completion, error, and cancellation to the UI thread.
 */
module auroraiso.job;

import core.thread : Thread;

final class Job : Thread
{
    private void delegate() _work;
    private string _title;
    private shared bool _cancelRequested;
    private bool _running;
    private bool _done;
    private bool _failed;
    private string _error;
    private string _message;
    private shared double _progress;

    this(string title, void delegate() work)
    {
        super(&runThread);
        _title = title;
        _work = work;
    }

    private void runThread()
    {
        _running = true;
        try
        {
            if (_work !is null)
                _work();
        }
        catch (Exception error)
        {
            _failed = true;
            _error = error.msg;
        }
        _running = false;
        _done = true;
    }

    void cancel() @trusted
    {
        _cancelRequested = true;
    }

    bool cancelled() @trusted
    {
        return _cancelRequested;
    }

    /// Called from the worker to publish progress (0..1) and a status message.
    void report(double fraction, string message) @trusted
    {
        _progress = fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
        _message = message;
    }

    string title() const @safe pure nothrow @nogc { return _title; }
    bool running() @trusted { return _running; }
    bool done() @trusted { return _done; }
    bool failed() @trusted { return _failed; }
    string error() @trusted { return _error; }
    string message() @trusted { return _message; }
    double progress() @trusted { return _progress; }
}
