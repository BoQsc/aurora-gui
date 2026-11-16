module tests.headless;

import aurora;
import std.file : mkdirRecurse;
import std.stdio : writeln;

private final class HeadlessGallery : VBox
{
    this()
    {
        super(10, Insets(14));
        auto heading = add(new Label("Aurora-D Headless Render Test"));
        heading.setScale(3);
        heading.layoutHints().preferredHeight = 38;

        auto row = add(new HBox(8));
        row.layoutHints().preferredHeight = 42;
        auto normal = row.add(new Button("Normal", IconKind.file));
        auto accent = row.add(new Button("Accent", IconKind.save));
        accent.setAccent(true);
        auto danger = row.add(new Button("Danger", IconKind.close));
        danger.setDanger(true);
        row.add(new Spacer());

        add(new CheckBox("DPI-aware draw list with sharp grayscale text", true));
        auto slider = add(new Slider(0, 100, 64));
        slider.layoutHints().preferredHeight = 32;
        auto progress = add(new ProgressBar(0.64));
        progress.setLabel("64% rendered");

        auto list = add(new ListView());
        list.setItems([
            ListItem("Vulkan renderer", IconKind.computer, "GPU triangles + swapchain"),
            ListItem("OpenType text layout", IconKind.start, "Unicode shaping + A8 atlas"),
            ListItem("Software fallback", IconKind.maximize, "Same ordered draw list")
        ]);
        list.setSelectedIndex(1, false);
        list.layoutHints().flex = 1.0;
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Headless Test";
    options.width = 760;
    options.height = 520;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new HeadlessGallery());
    const result = window.run();

    assert(window.surface().width() == 760);
    assert(window.surface().height() == 520);
    assert(window.surface().pixels().length == 760UL * 520UL);
    assert(window.rendererName() == "Software");

    // A real OpenType face should produce intermediate alpha values rather than
    // only the binary coverage of the emergency bitmap fallback.
    if (window.fontSystem().uiFace.isOpenType())
    {
        bool hasAntialiasing;
        foreach (coverage; window.fontSystem().atlas.pixels())
        {
            if (coverage > 0 && coverage < 255)
            {
                hasAntialiasing = true;
                break;
            }
        }
        assert(hasAntialiasing);
    }

    mkdirRecurse("build");
    window.saveScreenshot("build/aurora-headless.ppm");
    writeln("Headless render written to build/aurora-headless.ppm");
    return result;
}
