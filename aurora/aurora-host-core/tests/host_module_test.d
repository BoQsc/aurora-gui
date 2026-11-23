module host_module_test;

import aurorahost.host_module : HostModule;
import std.path : buildPath;
import std.stdio : writeln;

int main()
{
    const path = buildPath("build", "policy-module.dll");
    auto hostModule = new HostModule();
    hostModule.load(path);
    auto abi = cast(int function() @system) hostModule.symbol("aurora_module_abi");
    auto protect = cast(int function() @system) hostModule.symbol("aurora_module_protect");
    if (abi is null || protect is null)
        return 1;
    if (abi() != 2 || protect() != 1)
        return 2;
    hostModule.unload();
    if (hostModule.loaded())
        return 3;
    writeln("host module hot-load/unload passed: ABI 2 policy DLL");
    return 0;
}
