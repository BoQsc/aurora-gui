module retry_policy_contracts;
import auroraopencode.retrypolicy;
import core.time : Duration, seconds;
import std.stdio : writeln;

int main()
{
    auto policy = ProviderRetryPolicy(10.seconds);
    assert(policy.resend("Connection reset", 1, 9.seconds).retry);
    assert(!policy.resend("Connection reset", 1, 10.seconds).retry);
    assert(!policy.resend("HTTP 429 temporarily unavailable", 0, Duration.zero, false, true).retry);
    assert(!policy.resend("HTTP 401 invalid key", 0, Duration.zero).retry);
    assert(policy.resend("HTTP 401 invalid key", 0, Duration.zero, true).delayMs == 3000);
    assert(!policy.resend("Quota exhausted", 0, Duration.zero).retry);
    const reset = policy.resend("Usage limit reached. Resets in 3hr 52min", 0, Duration.zero);
    assert(reset.retry && reset.reason == RetryReason.quotaLimit && reset.delayMs == 13_920_000);
    assert(quotaResetDelayMs("resets in 999999999999999999999999999999999 days") == 86_400_000);
    auto unlimited = ProviderRetryPolicy(Duration.zero);
    assert(unlimited.resend("Connection reset", 1000, 100_000.seconds).retry);
    assert(!unlimited.resend("Connection reset", 1000, 100_000.seconds, false, true).retry);
    assert(autoResendDelayMs("Connection reset", 0) == 3000);
    assert(autoResendDelayMs("Connection reset", 100) == 30_000);
    assert(!policy.decide(429, 0, 10.seconds).retry);
    assert(policy.decide(429, 0, 9.seconds).retry);
    assert(!policy.decide(429, 0, Duration.zero, true).retry);
    writeln("PASS typed outage/replay policy, explicit reset waits, permanent failures, cancellation boundary and overflow-safe durations");
    return 0;
}
