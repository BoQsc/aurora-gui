module auroraopencode.usage_limits;

import core.sys.windows.windows : DWORD;
import std.array : array;
import std.csv : csvReader;
import core.sys.windows.wininet : HTTP_QUERY_FLAG_NUMBER,
    HTTP_QUERY_STATUS_CODE, HttpQueryInfoW, HINTERNET,
    INTERNET_FLAG_NO_CACHE_WRITE, INTERNET_FLAG_RELOAD,
    INTERNET_OPEN_TYPE_PRECONFIG, INTERNET_OPTION_CONNECT_TIMEOUT,
    INTERNET_OPTION_RECEIVE_TIMEOUT, InternetCloseHandle, InternetOpenUrlW,
    InternetOpenW, InternetReadFile, InternetSetOptionW;
import std.conv : to;
import std.datetime : Clock;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, startsWith, strip, toLower;
import std.utf : toUTF16z;

public struct UsageLimitWindow
{
    string label;
    double percent;
    string detail;
    string reset;
}

public struct UsageLimitsResult
{
    string title;
    UsageLimitWindow[] windows;
    string note;
    string planName;
    string planStatus;
    string planPeriod;
    string creditStatus;
    string serviceAccountName;
    string commandCodeUser;
    bool accountChecked;
    bool available;
}

public struct AccountPlan
{
    string name;
    string status;
    string period;
    bool available;
}

public string usageProviderForBaseUrl(string baseUrl)
{
    const url = baseUrl.strip().toLower();
    if (url.startsWith("https://opencode.ai/zen/go/v1")) return "opencode";
    if (url.startsWith("https://api.commandcode.ai/provider/v1"))
        return "commandcode";
    return "";
}

private const(JSONValue)* field(const(JSONValue)* value, string name)
{
    if (value is null || value.type != JSONType.object) return null;
    return name in value.object;
}

private double number(const(JSONValue)* value)
{
    if (value is null) return -1;
    if (value.type == JSONType.integer)
        return cast(double) value.integer;
    if (value.type == JSONType.float_)
        return value.floating;
    return -1;
}

private string text(const(JSONValue)* value)
{
    return value !is null && value.type == JSONType.string ? value.str : "";
}

private bool boolean(const(JSONValue)* value)
{
    return value !is null && value.type == JSONType.true_;
}

private string commandCodePlanName(string planId)
{
    const id = planId.toLower();
    if (id.indexOf("enterprise") >= 0) return "Enterprise";
    if (id.indexOf("provider") >= 0) return "Provider";
    if (id.indexOf("team") >= 0) return "Team Pro";
    if (id.indexOf("max") >= 0 && id.indexOf("20") >= 0) return "Max 20×";
    if (id.indexOf("max") >= 0) return "Max 10×";
    if (id.indexOf("goat") >= 0) return "GOAT";
    if (id.indexOf("pro") >= 0) return "Pro";
    if (id.indexOf("go") >= 0) return "Go";
    return planId.length > 0 ? planId : "Free / balance only";
}

private string commandCodePlanFromCaps(double fiveHour, double weekly)
{
    bool matches(double actual, double expected)
    {
        const delta = actual - expected;
        return delta > -0.001 && delta < 0.001;
    }
    if (matches(fiveHour, 3) && matches(weekly, 6)) return "Go";
    if (matches(fiveHour, 14) && matches(weekly, 35)) return "GOAT";
    if (matches(fiveHour, 16) && matches(weekly, 40)) return "Pro";
    if (matches(fiveHour, 45) && matches(weekly, 90)) return "Max 10×";
    if (matches(fiveHour, 90) && matches(weekly, 180)) return "Max 20×";
    if (matches(fiveHour, 12) && matches(weekly, 24)) return "Team Pro";
    return "";
}

private double commandCodeMonthlyCap(string planName)
{
    switch (planName)
    {
        case "Go": return 10;
        case "GOAT": return 70;
        case "Pro": return 80;
        case "Max 10×": return 150;
        case "Max 20×": return 300;
        case "Team Pro": return 40;
        default: return -1;
    }
}

private string planStatusLabel(string status)
{
    switch (status.toLower())
    {
        case "active": return "Active";
        case "trialing": return "Trial";
        case "past_due": return "Past due";
        case "canceled":
        case "cancelled": return "Canceled";
        case "expired": return "Expired";
        case "unpaid": return "Unpaid";
        case "incomplete": return "Incomplete";
        default: return status;
    }
}

private string resetFromUnixMilliseconds(const(JSONValue)* value)
{
    const millis = number(value);
    if (millis <= 0) return "";
    const seconds = cast(long) (millis / 1000) - Clock.currTime.toUnixTime();
    if (seconds <= 0) return "Reset due";
    if (seconds < 3_600) return "Resets in " ~
        to!string((seconds + 59) / 60) ~ "m";
    if (seconds < 86_400) return "Resets in " ~
        to!string(seconds / 3_600) ~ "h " ~
        to!string((seconds % 3_600) / 60) ~ "m";
    return "Resets in " ~ to!string(seconds / 86_400) ~ "d " ~
        to!string((seconds % 86_400) / 3_600) ~ "h";
}

public UsageLimitsResult parseUsageLimits(string provider, string body)
{
    UsageLimitsResult result;
    result.title = provider == "opencode" ? "OpenCode Go usage" :
        "CommandCode usage";
    auto root = parseJSON(body);
    if (provider == "opencode")
    {
        result.planName = "OpenCode Go";
        const usage = field(&root, "usage");
        string reportedStatus;
        foreach (index, name; ["rolling", "weekly", "monthly"])
        {
            const window = field(usage, name);
            const status = text(field(window, "status"));
            if (status == "expired" || status == "inactive" ||
                status == "canceled" || status == "cancelled")
                reportedStatus = status;
            const percent = number(field(window, "percent"));
            if (percent < 0) continue;
            UsageLimitWindow entry;
            entry.label = ["5 hours", "Week", "Month"][index];
            entry.percent = percent > 100 ? 100 : percent;
            entry.detail = format("%.0f%% used", percent);
            const reset = text(field(window, "resetsAt"));
            if (reset.length > 0)
                entry.reset = "Resets " ~ reset;
            result.windows ~= entry;
        }
        result.planStatus = reportedStatus.length > 0 ?
            planStatusLabel(reportedStatus) :
            (result.windows.length > 0 ? "Active" : "Unknown");
    }
    else if (provider == "commandcode")
    {
        const limits = field(&root, "windowLimits");
        double fiveHourCap = -1;
        double weeklyCap = -1;
        foreach (index, name; ["fiveHour", "weekly"])
        {
            const window = field(limits, name);
            const used = number(field(window, "used"));
            const cap = number(field(window, "cap"));
            if (used < 0 || cap <= 0) continue;
            if (index == 0) fiveHourCap = cap;
            else weeklyCap = cap;
            UsageLimitWindow entry;
            entry.label = ["5 hours", "Week"][index];
            entry.percent = used / cap * 100;
            if (entry.percent > 100) entry.percent = 100;
            entry.detail = format("$%.2f / $%.2f", used, cap);
            entry.reset = resetFromUnixMilliseconds(field(window, "resetAt"));
            result.windows ~= entry;
        }
        result.planName = commandCodePlanFromCaps(fiveHourCap, weeklyCap);
        if (result.planName.length > 0) result.planStatus = "Active (inferred)";
        const credits = field(&root, "credits");
        const monthly = number(field(credits, "monthlyCredits"));
        const purchased = number(field(credits, "purchasedCredits"));
        const free = number(field(credits, "freeCredits"));
        const threshold = number(field(credits, "creditThreshold"));
        double remaining = 0;
        bool remainingKnown;
        foreach (value; [monthly, purchased, free])
            if (value >= 0)
            {
                remaining += value;
                remainingKnown = true;
            }
        if (remainingKnown)
        {
            const low = boolean(field(credits, "belowThreshold")) ||
                (threshold > 0 && remaining <= threshold);
            result.creditStatus = remaining <= 0.0001 ?
                "Depleted — $0.00 remaining" :
                (low ? format("Low — $%.2f remaining", remaining) :
                    format("$%.2f remaining", remaining));
        }
        const monthlyCap = commandCodeMonthlyCap(result.planName);
        if (monthly >= 0 && monthlyCap > 0)
        {
            double used = monthlyCap - monthly;
            if (used < 0) used = 0;
            if (used > monthlyCap) used = monthlyCap;
            UsageLimitWindow entry;
            entry.label = "Month";
            entry.percent = used / monthlyCap * 100;
            entry.detail = format("$%.2f / $%.2f", used, monthlyCap);
            result.windows ~= entry;
        }
        if (monthly >= 0)
            result.note = format("Monthly credits left: $%.2f", monthly);
        if (purchased > 0 || free > 0)
            result.note ~= format("  Extra: $%.2f", (purchased > 0 ?
                purchased : 0) + (free > 0 ? free : 0));
    }
    result.available = result.windows.length > 0;
    if (!result.available) result.note = "Usage limits unavailable.";
    return result;
}

/// Parse the subscription metadata returned by CommandCode's billing API.
/// A successful null `data` value is meaningful: the key is valid but the
/// account has no subscription, so it is free/balance-only rather than expired.
public AccountPlan parseCommandCodePlan(string body)
{
    AccountPlan result;
    try
    {
        auto root = parseJSON(body);
        const success = field(&root, "success");
        if (success !is null && success.type == JSONType.false_) return result;
        const data = field(&root, "data");
        if (data is null || data.type != JSONType.object)
        {
            result.name = "Free / balance only";
            result.status = "No active subscription";
            result.available = success !is null && success.type == JSONType.true_;
            return result;
        }
        result.name = commandCodePlanName(text(field(data, "planId")));
        result.status = planStatusLabel(text(field(data, "status")));
        const periodEnd = text(field(data, "currentPeriodEnd"));
        if (periodEnd.length > 0)
        {
            const date = periodEnd.length >= 10 ? periodEnd[0 .. 10] : periodEnd;
            result.period = boolean(field(data, "cancelAtPeriodEnd")) ?
                "Ends " ~ date : "Renews " ~ date;
        }
        result.available = true;
    }
    catch (Exception) {}
    return result;
}

public UsageLimitsResult fetchUsageLimits(string provider, string apiKey)
{
    UsageLimitsResult result;
    result.title = provider == "opencode" ? "OpenCode Go usage" :
        "CommandCode usage";
    if (provider == "opencode") result.planName = "OpenCode Go";
    if (apiKey.length == 0 ||
        (provider != "opencode" && provider != "commandcode"))
    {
        result.note = "No supported provider key.";
        return result;
    }
    const url = provider == "opencode"
        ? "https://opencode.ai/zen/go/v1/usage"
        : "https://api.commandcode.ai/alpha/billing/credits";
    auto session = InternetOpenW(toUTF16z("Aurora OpenCode"),
        INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
    if (session is null)
    {
        result.note = "Could not connect to usage service.";
        return result;
    }
    scope (exit) InternetCloseHandle(session);
    DWORD timeout = 12_000;
    InternetSetOptionW(session, INTERNET_OPTION_CONNECT_TIMEOUT,
        &timeout, cast(DWORD) timeout.sizeof);
    InternetSetOptionW(session, INTERNET_OPTION_RECEIVE_TIMEOUT,
        &timeout, cast(DWORD) timeout.sizeof);
    const headers = "Authorization: Bearer " ~ apiKey ~ "\r\n" ~
        "Accept: application/json\r\n";
    auto request = InternetOpenUrlW(session, toUTF16z(url),
        toUTF16z(headers), -1, INTERNET_FLAG_RELOAD |
        INTERNET_FLAG_NO_CACHE_WRITE, 0);
    if (request is null)
    {
        result.note = "Could not load usage limits.";
        return result;
    }
    scope (exit) InternetCloseHandle(request);
    DWORD status;
    DWORD statusLength = cast(DWORD) status.sizeof;
    if (!HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE |
            HTTP_QUERY_FLAG_NUMBER, &status, &statusLength, null))
    {
        result.note = "Usage service returned no status.";
        return result;
    }
    if (status != 200)
    {
        result.note = "Usage unavailable (HTTP " ~ to!string(status) ~ ").";
        if (provider == "opencode")
            result.planStatus = status == 401 ? "Key rejected" :
                (status == 402 || status == 403 ?
                    "Unavailable or expired" : "Unknown");
        return result;
    }
    string body;
    ubyte[4096] buffer;
    while (body.length < 256_000)
    {
        DWORD readBytes;
        if (!InternetReadFile(request, buffer.ptr,
                cast(DWORD) buffer.length, &readBytes)) break;
        if (readBytes == 0) break;
        body ~= cast(string) buffer[0 .. readBytes].dup;
    }
    try return parseUsageLimits(provider, body);
    catch (Exception)
    {
        result.note = "Could not read usage limits.";
        return result;
    }
}

/// A workspace export can contain several service accounts. Use its label
/// only when every attributed row agrees, so it cannot silently label a key
/// with another account's name.
public string parseOpenCodeGoServiceAccountName(string body)
{
    try
    {
        auto records = csvReader(body, null);
        size_t index = size_t.max;
        foreach (i, name; records.header)
            if (name == "service_account_name")
            {
                index = i;
                break;
            }
        if (index == size_t.max) return "";
        string found;
        foreach (record; records)
        {
            const cells = record.array;
            if (index >= cells.length) return "";
            const name = cells[index].strip();
            if (name.length == 0) return "";
            if (found.length > 0 && name != found) return "";
            found = name;
        }
        return found;
    }
    catch (Exception) return "";
}

public string parseCommandCodeUser(string body)
{
    try
    {
        auto root = parseJSON(body);
        const user = field(&root, "user");
        if (user is null || user.type != JSONType.object) return "";
        auto name = text(field(user, "userName"));
        if (name.length == 0) name = text(field(user, "name"));
        const email = text(field(user, "email"));
        if (name.length == 0) return email;
        return email.length > 0 && email != name ?
            name ~ " (" ~ email ~ ")" : name;
    }
    catch (Exception) return "";
}

private string fetchAccountBody(string url, string apiKey, string accept,
    size_t maxBytes)
{
    if (apiKey.length == 0) return "";
    auto session = InternetOpenW(toUTF16z("Aurora OpenCode"),
        INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
    if (session is null) return "";
    scope (exit) InternetCloseHandle(session);
    DWORD timeout = 12_000;
    InternetSetOptionW(session, INTERNET_OPTION_CONNECT_TIMEOUT,
        &timeout, cast(DWORD) timeout.sizeof);
    InternetSetOptionW(session, INTERNET_OPTION_RECEIVE_TIMEOUT,
        &timeout, cast(DWORD) timeout.sizeof);
    const headers = "Authorization: Bearer " ~ apiKey ~ "\r\n" ~
        "Accept: " ~ accept ~ "\r\n";
    auto request = InternetOpenUrlW(session, toUTF16z(url),
        toUTF16z(headers), -1, INTERNET_FLAG_RELOAD |
        INTERNET_FLAG_NO_CACHE_WRITE, 0);
    if (request is null) return "";
    scope (exit) InternetCloseHandle(request);
    DWORD status;
    DWORD statusLength = cast(DWORD) status.sizeof;
    if (!HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE |
            HTTP_QUERY_FLAG_NUMBER, &status, &statusLength, null) ||
        status != 200) return "";
    string body;
    ubyte[4096] buffer;
    while (body.length <= maxBytes)
    {
        DWORD readBytes;
        if (!InternetReadFile(request, buffer.ptr,
                cast(DWORD) buffer.length, &readBytes)) return "";
        if (readBytes == 0) break;
        body ~= cast(string) buffer[0 .. readBytes].dup;
    }
    return body.length > maxBytes ? "" : body;
}

/// Returns an optional provider-supplied account hint, not a key owner.
/// The 24-hour export is bounded because large workspaces may have many rows.
public string fetchOpenCodeGoServiceAccountName(string apiKey)
{
    const body = fetchAccountBody(
        "https://opencode.ai/console/api/v1/usage/export" ~
        "?scope=organization&range=24h", apiKey, "text/csv", 2_000_000);
    return parseOpenCodeGoServiceAccountName(body);
}

/// CommandCode identifies the bearer key directly through /alpha/whoami.
public string fetchCommandCodeUser(string apiKey)
{
    const body = fetchAccountBody(
        "https://api.commandcode.ai/alpha/whoami", apiKey,
        "application/json", 32_000);
    return parseCommandCodeUser(body);
}

/// CommandCode exposes the subscription attached to the same bearer key used
/// for inference. This is more reliable than guessing a plan from balances;
/// the usage-window caps remain a fallback when this endpoint is unavailable.
public AccountPlan fetchCommandCodePlan(string apiKey)
{
    const body = fetchAccountBody(
        "https://api.commandcode.ai/alpha/billing/subscriptions", apiKey,
        "application/json", 64_000);
    return parseCommandCodePlan(body);
}
