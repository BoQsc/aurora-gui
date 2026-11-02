module auroraopencode.developerpolicy;

import auroraopencode.core : opencodeStateDirectory;
import auroraopencode.developerworkflow : DeveloperWorkflow, findDeveloperTool, developerOperationMutex;
import std.json : JSONType, parseJSON;

/// Values captured before dispatch; native workers never inspect host settings.
public struct DeveloperToolPolicy
{
    string source;
    bool requireLatest = true, autoReapply = true, operationPending;
}

public string sourceEditBlocked(const ref DeveloperToolPolicy policy, string[] paths, bool gitResolution)
{
    if (policy.operationPending) return "An Update, source operation or rebuild is pending. Wait for it before changing source.";
    if (!policy.source.length) return "";
    auto workflow = new DeveloperWorkflow(findDeveloperTool("git", opencodeStateDirectory()));
    auto result = workflow.checkSourceBeforeEdit(policy.source, paths, gitResolution, policy.requireLatest);
    return result.failed || result.available ? result.message : "";
}

public string syncCapturedSource(const ref DeveloperToolPolicy policy, string arguments)
{
    if (policy.operationPending) return "Error: An Update, source operation or rebuild is pending. Wait for it before syncing source.";
    if (!policy.source.length) return "Error: No Aurora source folder was captured for this request.";
    bool resolved;
    try
    {
        auto input = parseJSON(arguments);
        if (input.type == JSONType.object)
            if (auto field = "recoveryResolved" in input.object) resolved = field.type == JSONType.true_;
    }
    catch (Exception) {}
    synchronized (developerOperationMutex())
    {
        auto workflow = new DeveloperWorkflow(findDeveloperTool("git", opencodeStateDirectory()));
        return workflow.sync(policy.source, policy.autoReapply, resolved).message;
    }
}

public string sourceRebuildBlocked(const ref DeveloperToolPolicy policy)
{
    if (policy.operationPending) return "An Update, source operation or rebuild is pending. Wait for it before rebuilding.";
    auto workflow = new DeveloperWorkflow(findDeveloperTool("git", opencodeStateDirectory()));
    auto result = workflow.checkRebuildSource(policy.source, policy.requireLatest);
    return result.failed || result.available ? result.message : "";
}
