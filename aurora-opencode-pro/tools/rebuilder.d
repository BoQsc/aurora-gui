// Entry point for the standalone `aurora-rebuilder` executable.
//
// The entire rebuild feature - the `rebuildstate.json` protocol, the app-side
// launch flow, the resume notice, the Win32 progress window, and the detached
// helper logic - lives in `shared/rebuild.d`. This file exists only because the
// module cannot own `main` (the application imports it too, and a second `main`
// would collide); all it does is hand argv to `runRebuilder`.
module rebuilder;

import rebuild : runRebuilder;

int main(string[] args)
{
    return runRebuilder(args);
}
