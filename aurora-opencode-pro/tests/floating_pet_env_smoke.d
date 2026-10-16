import std.process : environment;
import std.stdio : writeln;

import auroraopencode.pet : experimentalPetEnabled, setFloatingPetSetting,
    floatingPetEnabledBySetting, observe, petFailureObservation,
    forgetPetProposals;

// The environment variable is a documented way to enable the pet, and the gate
// reads it live on every call. Assert both directions, and that an unrecognised
// value does NOT enable (a typo must fail closed, never open).
int main()
{
    setFloatingPetSetting(false);
    environment["AURORA_FLOATING_PET"] = "";
    assert(!experimentalPetEnabled(), "an empty value must leave the pet off");

    environment["AURORA_FLOATING_PET"] = "nonsense";
    assert(!experimentalPetEnabled(),
        "an unrecognised value must fail closed, not enable the pet");
    forgetPetProposals();
    assert(!observe(petFailureObservation(3)).propose,
        "a bogus value must not produce a proposal");
    writeln("PASS an unrecognised AURORA_FLOATING_PET value leaves the pet off");

    environment["AURORA_FLOATING_PET"] = "1";
    assert(experimentalPetEnabled(), "AURORA_FLOATING_PET=1 must enable the pet");
    forgetPetProposals();
    assert(observe(petFailureObservation(3)).propose,
        "an env-enabled pet should surface the observation");
    writeln("PASS AURORA_FLOATING_PET=1 enables the pet");

    // The setting wins when it is off: unsetting the variable must return to
    // dormant even though the env previously enabled it.
    environment["AURORA_FLOATING_PET"] = "";
    assert(!experimentalPetEnabled(),
        "clearing the variable must return the pet to dormant");
    writeln("PASS clearing the variable returns the pet to dormant");

    assert(!floatingPetEnabledBySetting, "the setting must still be off");
    writeln("floating pet env-gate smoke passed");
    return 0;
}
