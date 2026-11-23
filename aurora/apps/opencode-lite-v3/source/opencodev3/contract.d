module opencodev3.contract;

enum V3SchemaVersion = 3;
enum V3ModuleAbi = 1;
enum V3AppVersion = "3.0.0";

struct ModuleManifest
{
    string id = "opencode-lite-v3";
    uint abiVersion = V3ModuleAbi;
    uint schemaVersion = V3SchemaVersion;
    string appVersion = V3AppVersion;
}

/**
 * Stable boundary between the long-lived host shell and a replaceable v3 app
 * module. The shell owns the window; the module owns application policy.
 */
interface AppModule
{
    ModuleManifest manifest();
    void start();
    void service(double deltaSeconds);
    void stop();
}

/**
 * Host services exposed to an app module. It deliberately has no process,
 * window, cursor, or restart operations.
 */
interface HostShell
{
    string text(string node);
    bool setText(string node, string value);
    bool setEnabled(string node, bool enabled);
    bool trigger(string node, string action);
}

unittest
{
    auto manifest = ModuleManifest();
    assert(manifest.id == "opencode-lite-v3");
    assert(manifest.abiVersion == 1);
    assert(manifest.schemaVersion == 3);
    assert(manifest.appVersion == "3.0.0");
}
