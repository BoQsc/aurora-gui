module auroraremote.quality;

struct StreamProfile
{
    int width;
    int height;
    int intervalMs;
    string label;
}

final class AdaptiveQuality
{
    private int _level;
    private int _healthySamples;
    private int _strainSamples;

    StreamProfile profile() const
    {
        final switch (_level)
        {
            case 0: return StreamProfile(1280, 720, 33, "1280×720 30 FPS");
            case 1: return StreamProfile(960, 540, 50, "960×540 20 FPS");
            case 2: return StreamProfile(800, 450, 67, "800×450 15 FPS");
            case 3: return StreamProfile(640, 360, 100, "640×360 10 FPS");
        }
    }

    bool observe(long sendMilliseconds, size_t encodedBytes)
    {
        const previous = _level;
        const overloaded = sendMilliseconds > 110 || encodedBytes > 1_500_000;
        const strained = sendMilliseconds > 65 || encodedBytes > 900_000;
        if (overloaded && _level < 3)
        {
            ++_level;
            _healthySamples = 0;
            _strainSamples = 0;
        }
        else if (strained && _level < 3)
        {
            _healthySamples = 0;
            if (++_strainSamples >= 2)
            {
                ++_level;
                _strainSamples = 0;
            }
        }
        else if (sendMilliseconds < 25 && encodedBytes < 450_000)
        {
            ++_healthySamples;
            _strainSamples = 0;
            if (_healthySamples >= 120 && _level > 0)
            {
                --_level;
                _healthySamples = 0;
            }
        }
        else
        {
            _healthySamples = 0;
            _strainSamples = 0;
        }
        return previous != _level;
    }
}

unittest
{
    auto quality = new AdaptiveQuality;
    assert(quality.profile().width == 1280);
    assert(quality.observe(150, 100_000));
    assert(quality.profile().width == 960);
    assert(quality.observe(150, 100_000));
    assert(quality.profile().width == 800);
    assert(quality.observe(150, 100_000));
    assert(quality.profile().width == 640);
    foreach (_; 0 .. 120) quality.observe(5, 10_000);
    assert(quality.profile().width == 800);
}
