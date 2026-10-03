/**
 * The decision logic behind the one-button flow, kept pure so it can be tested
 * without touching the network or a disk.
 */
module auroraiso.installflow;

/// What the installer should do next for the chosen image.
enum InstallStep
{
    downloadThenInstall, // no usable local copy: download first
    writeExisting        // a complete local copy exists: go straight to writing
}

/**
 * Choose the first step for installing `url`.
 *
 * A previously downloaded image is reused, so the same distribution is never
 * downloaded twice. A zero-length file (an interrupted download) is treated as
 * missing and re-fetched.
 */
InstallStep firstInstallStep(bool cacheExists, ulong cacheSize)
{
    return cacheExists && cacheSize > 0
        ? InstallStep.writeExisting
        : InstallStep.downloadThenInstall;
}

unittest
{
    assert(firstInstallStep(false, 0) == InstallStep.downloadThenInstall);
    assert(firstInstallStep(true, 0) == InstallStep.downloadThenInstall);
    assert(firstInstallStep(true, 512) == InstallStep.writeExisting);
}
