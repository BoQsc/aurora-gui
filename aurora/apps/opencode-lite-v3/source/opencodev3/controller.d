module opencodev3.controller;

final class V3Controller
{
    private string _status = "Ready";
    private string _transcript = "New session.\n";
    private string _last;
    private string[] _pending;
    private bool _busy;

    void send(string text)
    {
        if (_busy || text.length == 0)
            return;
        _last = text;
        _transcript ~= "\nYou: " ~ text ~ "\nAssistant: ";
        _pending = ["stream-", "chunk-1", " chunk-2"];
        _busy = true;
        _status = "Streaming";
    }

    void service()
    {
        if (!_busy || _pending.length == 0)
            return;
        _transcript ~= _pending[0];
        _pending = _pending[1 .. $];
        if (_pending.length == 0)
        {
            _transcript ~= "\n";
            _busy = false;
            _status = "Complete";
        }
    }

    void stop()
    {
        _pending = [];
        if (_busy)
            _transcript ~= "\n[stopped]\n";
        _busy = false;
        _status = "Stopped";
    }

    void retry()
    {
        if (_last.length)
            send(_last);
    }

    string status() const { return _status; }
    string transcript() const { return _transcript; }
    bool busy() const { return _busy; }
}
