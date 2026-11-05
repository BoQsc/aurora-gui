module auroraopencode.tokenrate;

/// A bounded trailing decode window. Sampling also runs during provider silence,
/// so a stopped stream expires without waiting for another output event.
struct TokenRateWindow
{
    private struct Sample { long at, tokens; }
    /// Trailing span the live figure averages over. Short enough that a change
    /// in decode speed reaches the readout within a few hundred milliseconds
    /// instead of dragging a whole second of older samples behind it.
    long windowMs = 400;
    /// A stalled stream stops reporting a rate after this much silence, so the
    /// number fades out instead of freezing at the last measured speed.
    private enum long silenceResetMs = 1000;
    /// A slow decode cannot fill the short window, and averaging one or two
    /// tokens would make the number jump by whole token steps. The window is
    /// extended (up to the silence span) until it holds this many tokens, so a
    /// fast stream reacts in `windowMs` while a slow one stays readable.
    private enum long minWindowTokens = 8;
    private enum long sampleIntervalMs = 50;
    private Sample[24] samples;
    private size_t count;
    private long lastTokens, lastOutputAt;

    int observe(long tokens, long nowMs)
    {
        if (!count || tokens < lastTokens ||
            (tokens > lastTokens && nowMs - lastOutputAt >= silenceResetMs))
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
        while (count > 1 &&
            (samples[1].at <= nowMs - silenceResetMs ||
             (samples[1].at <= nowMs - windowMs &&
              tokens - samples[1].tokens >= minWindowTokens)))
        {
            foreach (i; 1 .. count) samples[i - 1] = samples[i];
            --count;
        }
        const elapsed = nowMs - samples[0].at;
        const produced = tokens - samples[0].tokens;
        // Publish nothing until the figure is measured over a full window (or
        // the longest span the silence rule allows, for a very slow decode).
        // A reading taken 100 ms in covers a handful of tokens, where one
        // buffered opening chunk can read 120 t/s for a 40 t/s stream.
        const complete = elapsed >= windowMs &&
            (produced >= minWindowTokens || elapsed >= silenceResetMs);
        const rate = complete && produced > 0 &&
            nowMs - lastOutputAt < silenceResetMs
            ? cast(int)((produced * 10_000 + elapsed / 2) / elapsed) : 0;
        // At most 21 samples cover a second at this cadence. No allocation is
        // needed on either the event path or the UI's periodic refresh.
        if (nowMs - samples[count - 1].at >= sampleIntervalMs)
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
