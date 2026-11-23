module runtime_policy_test;

import aurorahost.runtime_policy : FileRuntimePolicy;
import std.file : remove, write;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writeln;
import std.string : format;

int main()
{
    auto root = environment.get("TEMP", ".");
    const path = buildPath(root, "aurora-runtime-policy-test.json");
    scope (exit)
        if (__traits(compiles, remove(path))) remove(path);
    write(path, `{"protectHost":true,"allowInjectedInput":false,"clampGeometry":true}`);
    auto policy = new FileRuntimePolicy(path);
    if (!policy.current.protectHost || policy.current.allowInjectedInput)
        return 1;
    write(path, `{"protectHost":false,"allowInjectedInput":true,"clampGeometry":false}`);
    if (!policy.reload())
        return 2;
    if (policy.current.protectHost || !policy.current.allowInjectedInput)
        return 3;
    writeln("runtime policy reload passed: file-backed module changed live policy");
    return 0;
}
