module auroraopencode.retrypolicy;

import core.time : Duration, seconds, msecs;
import std.conv : to;
import std.process : environment;
import std.string : toLower, indexOf, startsWith;

public enum RetryReason { none, providerBusy, transientFailure, quotaLimit, transportFailure, invalidRequest, budgetExhausted }
public struct RetryDecision { bool retry; RetryReason reason; int delayMs; }

/// Bounds recovery from an unavailable provider, not useful generation or a
/// user task's duration. Zero explicitly requests an unlimited outage budget.
public struct ProviderRetryPolicy
{
    Duration outageBudget = 120.seconds;

    bool available(Duration elapsed) const pure nothrow @safe @nogc
    {
        return outageBudget == Duration.zero || elapsed < outageBudget;
    }

    private int boundedDelay(int delay, Duration elapsed) const pure nothrow @safe @nogc
    {
        if (outageBudget == Duration.zero) return delay;
        const remaining = (outageBudget - elapsed).total!"msecs";
        return remaining < 1 ? 1 : remaining < delay ? cast(int) remaining : delay;
    }

    RetryDecision resend(string failure, uint attempt, Duration elapsed,
        bool manual = false, bool exhausted = false) const
    {
        if (exhausted || !available(elapsed))
            return RetryDecision(false, RetryReason.budgetExhausted, 0);
        const delay = replayDelayMs(failure, attempt);
        if (delay < 0 && !manual) return RetryDecision(false, RetryReason.invalidRequest, 0);
        const reset = quotaResetDelayMs(failure) > 0;
        return RetryDecision(true, reset ? RetryReason.quotaLimit : RetryReason.transportFailure,
            reset ? cast(int) delay : boundedDelay(cast(int) (delay < 0 ? 3000 : delay), elapsed));
    }

    RetryDecision decide(uint status, uint nextAttempt, Duration elapsed,
        bool quotaWall = false) const pure nothrow @safe @nogc
    {
        if (quotaWall) return RetryDecision(false, RetryReason.quotaLimit, 0);
        if (status == 429)
            return RetryDecision(outageBudget == Duration.zero || elapsed < outageBudget,
                RetryReason.providerBusy, boundedDelay(3000, elapsed));
        if (status == 500 || status == 502 || status == 503 || status == 504)
            return RetryDecision(nextAttempt < 3 &&
                (outageBudget == Duration.zero || elapsed < outageBudget),
                RetryReason.transientFailure, boundedDelay(cast(int) nextAttempt * 250, elapsed));
        return RetryDecision.init;
    }
}

public ProviderRetryPolicy configuredProviderRetryPolicy()
{
    auto policy = ProviderRetryPolicy.init;
    const value = environment.get("AURORA_PROVIDER_OUTAGE_MS", "");
    if (value.length)
        try
        {
            const milliseconds = to!long(value);
            if (milliseconds >= 0) policy.outageBudget = milliseconds.msecs;
        }
        catch (Exception) {} // Invalid configuration retains the finite default.
    return policy;
}

public bool isPersistentRateLimit(string detail)
{
    return containsAsciiIgnoreCase(detail, "usage limit") ||
        containsAsciiIgnoreCase(detail, "limit reached") ||
        containsAsciiIgnoreCase(detail, "resets in") ||
        containsAsciiIgnoreCase(detail, "reset in") ||
        containsAsciiIgnoreCase(detail, "quota") ||
        containsAsciiIgnoreCase(detail, "available balance");
}

/// How long an automatic re-send may be postponed. Bounds a misread duration
/// ("reset in 9000 days") to something a running app can still honour.
private enum long maxAutoResendDelayMs = 86_400_000;

/**
 * How long to wait before sending a failed turn again on its own, in
 * milliseconds. Negative means "do not": the failure needs the user's
 * decision, and replaying it would only hide the reason the provider gave.
 *
 * `attempt` counts the automatic re-sends already made for this turn, so a
 * provider that stays unreachable is polled at a widening interval instead of
 * being hammered.
 *
 * A failed turn used to wait for the user to press Retry even when the
 * provider had already said exactly when it would accept work again.
 */
private long replayDelayMs(string failureText, uint attempt)
{
    // A stated reset time is the provider answering "when", so use it as given.
    const resetMs = quotaResetDelayMs(failureText);
    if (resetMs > 0)
        return resetMs > maxAutoResendDelayMs ? maxAutoResendDelayMs : resetMs;
    // A quota wall with no time, or a request the server rejected on its own
    // terms (a bad key, an unknown route), fails identically when replayed.
    // A 400 is deliberately NOT in this set: gateways route those to model
    // provisioning/model-not-ready conditions that answer a bare body such as
    // {"model":"..."} and clear on their own, so a random 400 used to kill the
    // turn outright. It is replayed on the same bounded schedule as any other
    // blip, and the provider's own sentence stays in the failed reply either
    // way, so nothing is hidden.
    if (isPersistentRateLimit(failureText)) return -1;
    if (containsAsciiIgnoreCase(failureText, "HTTP 401") ||
        containsAsciiIgnoreCase(failureText, "HTTP 403") ||
        containsAsciiIgnoreCase(failureText, "HTTP 404") ||
        containsAsciiIgnoreCase(failureText, "HTTP 422"))
        return -1;
    // Anything else is a transport or provider blip (a stream that died, a
    // gateway that refused, a socket error): wait, then send the same turn
    // again, backing off to half a minute.
    const delay = 3_000 + 3_000 * cast(long) attempt;
    return delay > 30_000 ? 30_000 : delay;
}

/**
 * Milliseconds until the moment a "... resets in 3hr 52min" notice names, or 0
 * when the failure text states no reset time.
 *
 * The provider's own sentence is the only reliable "when" available, so it is
 * read rather than guessed. The duration is scanned as number/unit pairs and
 * stops at the first pair without a unit, so the prose that follows
 * ("To continue using this model now, ...") cannot be misread as more time.
 */
public long quotaResetDelayMs(string failureText)
{
    const lower = failureText.toLower();
    const marker = lower.indexOf("reset");
    if (marker < 0) return 0;
    auto rest = lower[cast(size_t) marker + 5 .. $];
    // The notice reads "resets in <duration>" (or "reset in ...").
    const inIndex = rest.indexOf("in ");
    if (inIndex < 0 || inIndex > 3) return 0;
    rest = rest[cast(size_t) inIndex + 3 .. $];

    long total;
    size_t index;
    int fields;
    while (index < rest.length && fields < 4)
    {
        while (index < rest.length &&
            (rest[index] == ' ' || rest[index] == ',')) ++index;
        if (index >= rest.length || rest[index] < '0' || rest[index] > '9')
            break;
        long value;
        while (index < rest.length && rest[index] >= '0' && rest[index] <= '9')
        {
            value = value > maxAutoResendDelayMs / 10 ? maxAutoResendDelayMs :
                value * 10 + (rest[index] - '0');
            ++index;
        }
        while (index < rest.length && rest[index] == ' ') ++index;
        size_t unitLength;
        const unitMs = resetUnitMs(rest[index .. $], unitLength);
        if (unitMs == 0) break;
        index += unitLength;
        if (value >= maxAutoResendDelayMs / unitMs || total >= maxAutoResendDelayMs - value * unitMs)
            return maxAutoResendDelayMs;
        total += value * unitMs;
        ++fields;
    }
    return total;
}

/// Duration of the unit keyword at the start of `text`, and its length. Longest
/// keyword first, so "min" is not read as "m" followed by prose.
private long resetUnitMs(string text, out size_t length)
{
    static immutable string[] words = ["days", "day", "hours", "hour", "hrs",
        "hr", "minutes", "minute", "mins", "min", "seconds", "second", "secs",
        "sec", "h", "m", "s"];
    static immutable long[] durations = [86_400_000, 86_400_000, 3_600_000,
        3_600_000, 3_600_000, 3_600_000, 60_000, 60_000, 60_000, 60_000,
        1_000, 1_000, 1_000, 1_000, 3_600_000, 60_000, 1_000];
    foreach (index, word; words)
        if (startsWithAscii(text, word))
        {
            length = word.length;
            return durations[index];
        }
    length = 0;
    return 0;
}


/// Compatibility API uses the same policy as terminal request recovery.
public long autoResendDelayMs(string failure, uint attempt)
{
    const result = ProviderRetryPolicy.init.resend(failure, attempt, Duration.zero);
    return result.retry ? result.delayMs : -1;
}

private bool containsAsciiIgnoreCase(string text, string fragment)
{
    return text.toLower().indexOf(fragment.toLower()) >= 0;
}

private bool startsWithAscii(string text, string prefix)
{
    return text.startsWith(prefix);
}
