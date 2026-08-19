module aurorastream.appversion;

/** Public application identity used by the title bar, logs, and CLI.
 * Regenerated from dub.json by scripts/version.py; do not edit. */
enum appName = "Aurora Stream";
enum appVersion = "0.66.5";
enum appBuildId = "dev";
enum appDisplayName = appName ~ " " ~ appVersion;
enum appFullVersion = appDisplayName ~ " (build " ~ appBuildId ~ ")";
