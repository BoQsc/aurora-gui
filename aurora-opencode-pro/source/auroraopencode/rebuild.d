module auroraopencode.rebuildplaceholder;

// Temporary placeholder.
//
// The binary that is currently running predates this refactor: its
// `isAuroraProject` probe checks for the existence of this path to decide
// whether it may rebuild itself. It must exist for that older build to hand the
// first build off to the helper. The consolidated module now lives in
// `shared/rebuild.d`; this file is removed once the rebuilt app is running.
