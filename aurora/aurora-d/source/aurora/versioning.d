/** Aurora-D package version information. */
module aurora.versioning;

/** Semantic version of the public Aurora-D package. */
enum AuroraVersion = "2.0.0";

enum AuroraVersionMajor = 2;
enum AuroraVersionMinor = 0;
enum AuroraVersionPatch = 0;

unittest
{
    static assert(AuroraVersion == "2.0.0");
    static assert(AuroraVersionMajor == 2);
    static assert(AuroraVersionMinor == 0);
    static assert(AuroraVersionPatch == 0);
}
