/** Aurora-D package version information. */
module aurora.versioning;

/** Semantic version of the public Aurora-D package. */
enum AuroraVersion = "0.4.5";

enum AuroraVersionMajor = 0;
enum AuroraVersionMinor = 4;
enum AuroraVersionPatch = 5;

unittest
{
    static assert(AuroraVersion == "0.4.5");
    static assert(AuroraVersionMajor == 0);
    static assert(AuroraVersionMinor == 4);
    static assert(AuroraVersionPatch == 5);
}
