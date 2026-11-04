module auroraopencode.tokenrate;

/// A bounded trailing decode window. Sampling also runs during provider silence,
/// so a stopped stream expires without waiting for another output event.
struct TokenRateWindow
{
    private struct Sample { long at, tokens; }
    private Sample[24] samples;
    private size_t count;
    private long lastTokens, lastOutputAt;

    int observe(long tokens, long nowMs)
    {
        if (!count || tokens < lastTokens ||
            (tokens > lastTokens && nowMs - lastOutputAt >= 1000))
        {
            samples[0] = Sample(nowMs, tokens);
            count = 1;
            lastTokens = tokens;
            lastOutputAt = nowMs;
            return 0;
        }
        if (tokens > lastTokens) lastOutputAt = nowMs;
        lastTokens = tokens;
        // Retain the latest sample at or before the trailing boundary. Sparse
        // events must not pretend that all intervening tokens arrived at once.
        while (count > 1 && samples[1].at <= nowMs - 1000)
        {
            foreach (i; 1 .. count) samples[i - 1] = samples[i];
            --count;
        }
        const elapsed = nowMs - samples[0].at;
        const produced = tokens - samples[0].tokens;
        const rate = elapsed >= 100 && produced > 0 && nowMs - lastOutputAt < 1000
            ? cast(int)((produced * 10_000 + elapsed / 2) / elapsed) : 0;
        // At most 21 samples cover a second at this cadence. No allocation is
        // needed on either the event path or the UI's periodic refresh.
        if (nowMs - samples[count - 1].at >= 50)
        {
            if (count == samples.length)
            {
                foreach (i; 1 .. count) samples[i - 1] = samples[i];
                --count;
            }
            samples[count++] = Sample(nowMs, tokens);
        }
        return rate;
    }
}
