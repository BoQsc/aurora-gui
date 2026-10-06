module auroraopencode.retrypolicy;

import core.time : Duration, seconds, msecs;
import std.conv : to;
import std.process : environment;

public enum RetryReason { none, providerBusy, transientFailure, quotaLimit }
public struct RetryDecision { bool retry; RetryReason reason; int delayMs; }

/// Bounds recovery from an unavailable provider, not useful generation or a
/// user task's duration. Zero explicitly requests an unlimited outage budget.
public struct ProviderRetryPolicy
{
    Duration outageBudget = 120.seconds;

    RetryDecision decide(uint status, uint nextAttempt, Duration elapsed,
        bool quotaWall = false) const pure nothrow @safe @nogc
    {
        if (quotaWall) return RetryDecision(false, RetryReason.quotaLimit, 0);
        if (status == 429)
            return RetryDecision(outageBudget == Duration.zero || elapsed < outageBudget,
                RetryReason.providerBusy, 3000);
        if (status == 500 || status == 502 || status == 503 || status == 504)
            return RetryDecision(nextAttempt < 3 &&
                (outageBudget == Duration.zero || elapsed < outageBudget),
                RetryReason.transientFailure, cast(int) nextAttempt * 250);
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
