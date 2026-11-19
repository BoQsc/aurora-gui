import engine.atmosphere : clockText, paletteForTime, phaseName,
    sunDirectionAt;
import engine.runtime : defaultRuntime;
import std.math : abs;
import std.stdio : writeln;

void main()
{
    assert(clockText(0.0) == "00:00", "midnight clock text");
    assert(clockText(9.0) == "09:00", "morning clock text");
    assert(clockText(18.5) == "18:30", "evening clock text");
    assert(clockText(23.99) == "23:59", "last minute clock text");
    assert(clockText(24.0) == "00:00", "clock wraps at midnight");
    assert(phaseName(2.0) == "NIGHT", "night phase");
    assert(phaseName(6.0) == "DAWN", "dawn phase");
    assert(phaseName(12.0) == "DAY", "day phase");
    assert(phaseName(18.5) == "DUSK", "dusk phase");

    const noon = sunDirectionAt(12.0);
    const midnight = sunDirectionAt(0.0);
    const sunrise = sunDirectionAt(6.0);
    const sunset = sunDirectionAt(18.0);
    assert(noon[1] > 0.9f, "noon sun must be overhead");
    assert(midnight[1] < -0.9f, "midnight sun must be below the horizon");
    assert(abs(sunrise[1]) < 0.05f, "sunrise sun must sit on the horizon");
    assert(abs(sunset[1]) < 0.05f, "sunset sun must sit on the horizon");
    assert(sunrise[0] > 0.9f, "sunrise must be in the east");
    assert(sunset[0] < -0.9f, "sunset must be in the west");

    const auto day = paletteForTime(12.0);
    const auto night = paletteForTime(0.0);
    const auto dawn = paletteForTime(6.0);
    assert(day.tint[0] > 0.9f && day.tint[1] > 0.9f,
        "daylight tint must be bright");
    assert(night.tint[0] < 0.35f && night.tint[1] < 0.35f,
        "night tint must be dark");
    assert(day.fog[0] > 0.4f && day.fog[1] > 0.5f,
        "day fog must read as sky haze");
    assert(night.fog[0] < 0.10f, "night fog must be dark");
    assert(dawn.sun[0] > dawn.sun[2],
        "dawn sun must be warm rather than blue");
    assert(dawn.horizon[0] > dawn.horizon[2],
        "dawn horizon must carry the warm band");
    assert(day.sunIntensity > night.sunIntensity,
        "daylight must be stronger than night");
    foreach (palette; [day, night, dawn])
        foreach (channel; 0 .. 3)
        {
            assert(palette.zenith[channel] >= 0 && palette.zenith[channel] <= 1,
                "zenith palette out of range");
            assert(palette.horizon[channel] >= 0 && palette.horizon[channel] <= 1,
                "horizon palette out of range");
            assert(palette.fog[channel] >= 0 && palette.fog[channel] <= 1,
                "fog palette out of range");
        }

    auto runtime = defaultRuntime();
    assert(runtime.timeOfDay == 9.0, "default start time");
    const before = runtime.timeOfDay;
    runtime.advanceTime(runtime.dayLengthSeconds / 24.0);
    assert(runtime.timeOfDay > before, "clock did not advance");
    const wrapped = runtime.timeOfDay;
    runtime.timeOfDay = 23.9;
    runtime.advanceTime(runtime.dayLengthSeconds / 24.0);
    assert(runtime.timeOfDay < 1.0, "clock did not wrap past midnight");
    assert(runtime.timeOfDay > 0.0, "wrapped clock lost its progress");
    assert(runtime.timeOfDay != wrapped, "clock did not move after wrap");

    runtime.timePaused = true;
    const paused = runtime.timeOfDay;
    runtime.advanceTime(10.0);
    assert(runtime.timeOfDay == paused, "paused clock still advanced");

    writeln("PASS v2 atmosphere: clock, sun path, day/night palettes, ",
        "fog and runtime time advance");
}
