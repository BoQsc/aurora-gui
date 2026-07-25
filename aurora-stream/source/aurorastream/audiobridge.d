module aurorastream.audiobridge;

import aurorastream.wasapi : runWasapiRtpBridge;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : exists, readText, remove, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : Config, Pid, kill, spawnProcess, wait;
import std.socket : AddressFamily, InternetAddress, UdpSocket;
import std.string : startsWith, strip;

version (Windows)
{
    import core.sys.windows.windows : GetLastError, HANDLE,
        HANDLE_FLAG_INHERIT, SetHandleInformation;
}

private struct RtpReceiverReservation
{
    UdpSocket rtpSocket;
    UdpSocket rtcpSocket;
    ushort rtpPort;
    ushort rtcpPort;
}

private void closeSocket(ref UdpSocket socket)
{
    if (socket is null) return;
    try socket.close();
    catch (Exception) {}
    socket = null;
}

private void preventSocketInheritance(UdpSocket socket)
{
    version (Windows)
    {
        if (socket is null) return;
        auto handle = cast(HANDLE) cast(size_t) socket.handle;
        if (SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0U) == 0)
            throw new Exception(format(
                "Could not mark a UDP reservation handle as non-inheritable " ~
                "(Windows error %s).", GetLastError()));
    }
}

private RtpReceiverReservation bindLocalRtpReceiverPair(ushort rtpPort,
    ushort rtcpPort)
{
    UdpSocket rtpSocket;
    UdpSocket rtcpSocket;
    try
    {
        rtpSocket = new UdpSocket(AddressFamily.INET);
        rtcpSocket = new UdpSocket(AddressFamily.INET);
        preventSocketInheritance(rtpSocket);
        preventSocketInheritance(rtcpSocket);
        rtpSocket.bind(new InternetAddress("127.0.0.1", rtpPort));
        rtcpSocket.bind(new InternetAddress("127.0.0.1", rtcpPort));

        RtpReceiverReservation result;
        result.rtpSocket = rtpSocket;
        result.rtcpSocket = rtcpSocket;
        result.rtpPort = rtpPort;
        result.rtcpPort = rtcpPort;
        return result;
    }
    catch (Exception bindError)
    {
        closeSocket(rtpSocket);
        closeSocket(rtcpSocket);
        throw bindError;
    }
}

private RtpReceiverReservation reserveLocalRtpReceiverPair()
{
    // FFmpeg's RTP demuxer owns two adjacent local UDP ports: RTP on an
    // even port and RTCP on the following odd port. Keep both sockets bound
    // until the helper has explicitly bound its own source socket. This
    // prevents the sender's automatic local-port allocation from stealing
    // the future FFmpeg receive port on Windows.
    foreach (attempt; 0 .. 128)
    {
        UdpSocket candidateSocket;
        try
        {
            candidateSocket = new UdpSocket(AddressFamily.INET);
            candidateSocket.bind(new InternetAddress("127.0.0.1",
                InternetAddress.PORT_ANY));
            auto candidateAddress = cast(InternetAddress)
                candidateSocket.localAddress;
            if (candidateAddress is null || candidateAddress.port == 0)
                throw new Exception("Windows did not allocate a UDP port.");

            uint candidatePort = candidateAddress.port;
            candidatePort &= ~1U;
            closeSocket(candidateSocket);
            if (candidatePort < 1024 || candidatePort > 65_534) continue;

            const rtpPort = cast(ushort) candidatePort;
            const rtcpPort = cast(ushort)(candidatePort + 1);
            return bindLocalRtpReceiverPair(rtpPort, rtcpPort);
        }
        catch (Exception)
        {
            closeSocket(candidateSocket);
        }
    }
    throw new Exception(
        "Could not reserve an adjacent localhost RTP/RTCP port pair.");
}

private void removeIfPresent(string path)
{
    if (path.length == 0) return;
    try if (exists(path)) remove(path);
    catch (Exception) {}
}

private string sdpText(ushort port, ushort rtcpPort)
{
    return format(
        "v=0\r\n" ~
        "o=- 0 0 IN IP4 127.0.0.1\r\n" ~
        "s=Aurora Stream desktop audio\r\n" ~
        "c=IN IP4 127.0.0.1\r\n" ~
        "t=0 0\r\n" ~
        "m=audio %s RTP/AVP 96\r\n" ~
        "a=rtpmap:96 L16/48000/2\r\n" ~
        "a=rtcp:%s IN IP4 127.0.0.1\r\n" ~
        "a=ptime:20\r\n" ~
        "a=recvonly\r\n", port, rtcpPort);
}

final class AudioBridgeSession
{
    private string _executablePath;
    private Pid _process;
    private ushort _port;
    private ushort _rtcpPort;
    private UdpSocket _rtpReservation;
    private UdpSocket _rtcpReservation;
    private string _sdpPath;
    private string _statusPath;
    private string _stopPath;
    private string _metricsPath;
    private string _finalMetrics;
    private bool _running;

    this(string executablePath)
    {
        _executablePath = executablePath;
    }

    @property string sdpPath() const
    {
        return _sdpPath;
    }

    @property ushort port() const
    {
        return _port;
    }

    @property ushort rtcpPort() const
    {
        return _rtcpPort;
    }

    void releaseReceiverReservations()
    {
        closeSocket(_rtpReservation);
        closeSocket(_rtcpReservation);
    }

    bool validateReceiverReservationHandoff(out string error)
    {
        error = "";
        if (_port == 0 || _rtcpPort == 0)
        {
            error = "The desktop-audio receiver ports were not allocated.";
            return false;
        }

        // Closing and immediately reacquiring the same pair proves that the
        // helper did not inherit a duplicate of either reservation socket.
        // Keep the refreshed pair bound until the instant before FFmpeg is
        // launched so no unrelated process can take the ports meanwhile.
        releaseReceiverReservations();
        try
        {
            auto refreshed = bindLocalRtpReceiverPair(_port, _rtcpPort);
            _rtpReservation = refreshed.rtpSocket;
            _rtcpReservation = refreshed.rtcpSocket;
            return true;
        }
        catch (Exception handoffError)
        {
            error = format(
                "RTP/RTCP receiver-port handoff failed for %s/%s: %s " ~
                "The audio helper may still own an inherited reservation " ~
                "handle.", _port, _rtcpPort, handoffError.msg);
            return false;
        }
    }

    bool start(string endpointId, bool synthetic, out string error)
    {
        error = "";
        if (_running)
        {
            error = "The isolated desktop-audio helper is already running.";
            return false;
        }
        if (_executablePath.strip().length == 0)
        {
            error = "Aurora Stream could not resolve its executable path.";
            return false;
        }
        if (!synthetic && endpointId.strip().length == 0)
        {
            error = "No Windows playback endpoint is selected.";
            return false;
        }

        try
        {
            auto reservation = reserveLocalRtpReceiverPair();
            _port = reservation.rtpPort;
            _rtcpPort = reservation.rtcpPort;
            _rtpReservation = reservation.rtpSocket;
            _rtcpReservation = reservation.rtcpSocket;
            const token = format("aurora-stream-audio-%s-%s", _port,
                _rtcpPort);
            _sdpPath = buildPath(tempDir(), token ~ ".sdp");
            _statusPath = buildPath(tempDir(), token ~ ".status");
            _stopPath = buildPath(tempDir(), token ~ ".stop");
            _metricsPath = buildPath(tempDir(), token ~ ".metrics");
            _finalMetrics = "";
            removeIfPresent(_sdpPath);
            removeIfPresent(_statusPath);
            removeIfPresent(_stopPath);
            removeIfPresent(_metricsPath);
            write(_sdpPath, sdpText(_port, _rtcpPort));

            string[] arguments = [
                _executablePath,
                "--audio-rtp-helper",
                "--port", _port.to!string,
                "--status", _statusPath,
                "--stop", _stopPath,
                "--metrics", _metricsPath
            ];
            if (synthetic)
                arguments ~= ["--synthetic"];
            else
                arguments ~= ["--endpoint", endpointId.strip().idup];

            _process = spawnProcess(arguments,
                cast(const string[string]) null, Config.suppressConsole);
            _running = true;

            foreach (attempt; 0 .. 500)
            {
                if (exists(_statusPath))
                {
                    const status = readText(_statusPath).strip();
                    if (status == "ready" || status == "capturing")
                        return true;
                    if (status.startsWith("error:"))
                    {
                        error = status[6 .. $].strip().idup;
                        shutdown();
                        return false;
                    }
                }
                Thread.sleep(10.msecs);
            }

            error = synthetic ?
                "The isolated RTP silence helper did not become ready." :
                "The isolated WASAPI RTP helper did not become ready within five seconds.";
            shutdown();
            return false;
        }
        catch (Exception startError)
        {
            error = "Could not start the isolated desktop-audio helper: " ~
                startError.msg;
            shutdown();
            return false;
        }
    }

    bool captureActive()
    {
        if (!_running || _statusPath.length == 0 || !exists(_statusPath))
            return false;
        try return readText(_statusPath).strip() == "capturing";
        catch (Exception) return false;
    }

    string failure()
    {
        if (!_running || _statusPath.length == 0 || !exists(_statusPath))
            return "";
        try
        {
            const status = readText(_statusPath).strip();
            if (status.startsWith("error:"))
                return status[6 .. $].strip().idup;
        }
        catch (Exception) {}
        return "";
    }

    string metricsText()
    {
        if (_metricsPath.length > 0 && exists(_metricsPath))
        {
            try return readText(_metricsPath).strip().idup;
            catch (Exception) {}
        }
        return _finalMetrics;
    }

    void shutdown()
    {
        releaseReceiverReservations();
        if (_running)
        {
            try write(_stopPath, "stop\r\n");
            catch (Exception) {}
            // The helper publishes final counters while leaving its main loop.
            // Give that isolated process a bounded opportunity to flush them,
            // then terminate only as a last-resort cleanup operation.
            Thread.sleep(180.msecs);
        }

        if (_metricsPath.length > 0 && exists(_metricsPath))
        {
            try _finalMetrics = readText(_metricsPath).strip().idup;
            catch (Exception) {}
        }

        if (_running && _process !is null)
        {
            try kill(_process);
            catch (Exception) {}
            try wait(_process);
            catch (Exception) {}
        }

        if (_metricsPath.length > 0 && exists(_metricsPath))
        {
            try _finalMetrics = readText(_metricsPath).strip().idup;
            catch (Exception) {}
        }

        _running = false;
        _process = null;
        removeIfPresent(_sdpPath);
        removeIfPresent(_statusPath);
        removeIfPresent(_stopPath);
        removeIfPresent(_metricsPath);
    }
}

private string optionValue(const string[] arguments, string option)
{
    foreach (index; 0 .. arguments.length)
    {
        if (arguments[index] == option && index + 1 < arguments.length)
            return arguments[index + 1];
    }
    return "";
}

int runAudioBridgeHelper(string[] arguments)
{
    try
    {
        const portText = optionValue(arguments, "--port");
        const statusPath = optionValue(arguments, "--status");
        const stopPath = optionValue(arguments, "--stop");
        const metricsPath = optionValue(arguments, "--metrics");
        const endpointId = optionValue(arguments, "--endpoint");
        bool synthetic;
        foreach (argument; arguments)
            if (argument == "--synthetic") synthetic = true;

        if (portText.length == 0 || statusPath.length == 0 ||
            stopPath.length == 0 || metricsPath.length == 0)
            return 2;
        return runWasapiRtpBridge(endpointId, portText.to!ushort,
            statusPath, stopPath, metricsPath, synthetic);
    }
    catch (Exception error)
    {
        const statusPath = optionValue(arguments, "--status");
        if (statusPath.length > 0)
        {
            try write(statusPath, "error:" ~ error.msg ~ "\r\n");
            catch (Exception) {}
        }
        return 2;
    }
}
