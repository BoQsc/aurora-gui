/// Minimal Windows waveOut playback for rendered audio.
module auroramusic.player;

import std.stdio : writeln;

/// Play interleaved stereo floats in [-1, 1]. No-op message on non-Windows.
void playSamples(const(float)[] interleaved, int sampleRate)
{
    version (Windows)
    {
        playWindows(interleaved, sampleRate);
    }
    else
    {
        writeln("Playback is only implemented on Windows; the WAV file was written.");
    }
}

version (Windows) private void playWindows(const(float)[] interleaved,
    int sampleRate)
{
    import core.sys.windows.mmsystem : CALLBACK_NULL, HWAVEOUT, MMSYSERR_NOERROR,
        WAVE_MAPPER, WAVE_FORMAT_PCM, WAVEFORMATEX, WAVEHDR, WHDR_DONE,
        waveOutClose, waveOutOpen, waveOutPrepareHeader, waveOutUnprepareHeader,
        waveOutWrite;
    import core.thread : Thread;
    import core.time : msecs;
    import core.sys.windows.windef : DWORD, WORD;

    size_t frames = interleaved.length / 2;
    if (frames == 0) return;

    short[] pcm = new short[frames * 2];
    foreach (i, v; interleaved)
    {
        double s = v;
        if (s > 1.0) s = 1.0;
        else if (s < -1.0) s = -1.0;
        pcm[i] = cast(short)(s * 32767.0);
    }

    WAVEFORMATEX fmt;
    fmt.wFormatTag = WAVE_FORMAT_PCM;
    fmt.nChannels = 2;
    fmt.nSamplesPerSec = cast(DWORD) sampleRate;
    fmt.wBitsPerSample = 16;
    fmt.nBlockAlign = cast(WORD)(fmt.nChannels * fmt.wBitsPerSample / 8);
    fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
    fmt.cbSize = 0;

    HWAVEOUT hwo;
    if (waveOutOpen(&hwo, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) !=
        MMSYSERR_NOERROR)
    {
        writeln("Could not open the audio output device.");
        return;
    }

    enum int chunkFrames = 8192;
    enum int queueDepth = 4;
    size_t chunkCount = (frames + chunkFrames - 1) / chunkFrames;
    WAVEHDR[] headers = new WAVEHDR[chunkCount];

    foreach (c; 0 .. chunkCount)
    {
        size_t first = c * chunkFrames;
        size_t count = frames - first;
        if (count > chunkFrames) count = chunkFrames;

        headers[c].lpData = cast(char*) &pcm[first * 2];
        headers[c].dwBufferLength = cast(DWORD)(count * 2 * short.sizeof);
        headers[c].dwFlags = 0;
        headers[c].dwLoops = 0;
        waveOutPrepareHeader(hwo, &headers[c], WAVEHDR.sizeof);
        waveOutWrite(hwo, &headers[c], WAVEHDR.sizeof);

        if (c >= queueDepth)
        {
            WAVEHDR* done = &headers[c - queueDepth];
            while ((done.dwFlags & WHDR_DONE) == 0) Thread.sleep(4.msecs);
        }
    }

    foreach (ref h; headers)
        while ((h.dwFlags & WHDR_DONE) == 0) Thread.sleep(4.msecs);

    foreach (ref h; headers)
        waveOutUnprepareHeader(hwo, &h, WAVEHDR.sizeof);

    waveOutClose(hwo);
}
