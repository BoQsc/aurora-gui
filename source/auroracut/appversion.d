module auroracut.appversion;

/** Public application identity used by the title bar, logs, and CLI.
 * Regenerated from dub.json by scripts/version.py; do not edit. */
enum appName = "Aurora Cut";
enum appVersion = "0.60.0";
enum appBuildId = "dev";
enum appDisplayName = appName ~ " " ~ appVersion;
enum appFullVersion = appDisplayName ~ " (build " ~ appBuildId ~ ")";
