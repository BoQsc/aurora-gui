module contract_main;

import opencodev3.contract : ModuleManifest, V3AppVersion,
    V3ModuleAbi, V3SchemaVersion;
import std.stdio : writeln;

int main()
{
    const manifest = ModuleManifest();
    if (manifest.abiVersion != V3ModuleAbi)
        return 1;
    if (manifest.schemaVersion != V3SchemaVersion)
        return 2;
    if (manifest.appVersion != V3AppVersion)
        return 3;
    if (manifest.id != "opencode-lite-v3")
        return 4;
    writeln("v3 contract passed: abi=", manifest.abiVersion,
        " schema=", manifest.schemaVersion,
        " version=", manifest.appVersion);
    return 0;
}
