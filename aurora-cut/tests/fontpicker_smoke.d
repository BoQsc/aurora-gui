module fontpicker_smoke;

import aurora;
import auroracut.textfonts : FontPickerPopup, showFontPicker,
    installedTextFontFamilies;
import aurora.types : Point, Rect, Size;
import std.string : indexOf, toLower;
import std.stdio : writeln;

/// Verifies the searchable font picker: live filtering by typed text plus the
/// built-in right-side scrollbar (ListView), and that a pick is fired ONLY on
/// explicit activation - never on a filter-driven re-select (the regression
/// where typing into the search box dismissed the popup).
int main()
{
    WindowOptions options;
    options.title = "fontpicker";
    options.width = 800;
    options.height = 600;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new WidgetTestRoot();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 800, 600));
    root.layoutTree();

    const all = installedTextFontFamilies();
    writeln("installed families = ", all.length);
    assert(all.length >= 20, "not enough installed families");

    // Build the picker popup.
    int pickCount;
    auto picker = new FontPickerPopup("Segoe UI");
    picker.onFamilyPicked = delegate(string family) { ++pickCount; };
    root.add(picker);
    picker.setBounds(Rect(0, 0, 360, 460));
    picker.layoutTree();

    // Initially lists every installed family and selects the current one.
    const initial = picker.filteredFamilies();
    writeln("initially filtered = ", initial.length);
    assert(initial.length >= 20, "picker did not load the full set");
    assert(picker.listView().items().length == initial.length,
        "list did not reflect the filter");
    assert(picker.listView().verticalScrollbar().visible(),
        "no scrollbar shown for a long list");
    const picksAfterInit = pickCount;
    assert(picksAfterInit == 0,
        "constructing the picker must not fire a pick");

    // REGRESSION: typing to filter must NOT dismiss (no pick fired).
    picker.searchField().setText("consol", true);
    picker.searchField().onChanged();
    const filtered = picker.filteredFamilies();
    writeln("after 'consol' filtered = ", filtered.length,
        "  [", (filtered.length > 0 ? filtered[0] : ""), "]");
    assert(filtered.length >= 1, "no match for 'consol'");
    for (size_t i = 0; i < filtered.length; ++i)
        assert(filtered[i].toLower().indexOf("consol") >= 0,
            "non-matching family survived the filter");
    assert(pickCount == picksAfterInit,
        "typing to filter must not fire a pick / dismiss the popup");

    // A user click (single selection) on a different row should pick once.
    // (Row 0 is already selected by the filter, so a click on row 1 is a real
    // user-initiated selection change.)
    if (filtered.length > 1)
        picker.listView().setSelectedIndex(1, true, true);
    assert(pickCount == picksAfterInit + 1,
        "clicking a row must pick exactly one family");

    // Double-click / Enter (activation) also picks.
    int activatedCount = pickCount;
    if (auto activate = picker.listView().onActivated) activate(0);
    assert(pickCount == activatedCount + 1, "activation must pick once");

    // Clearing the filter restores the full list without firing another pick.
    picker.searchField().setText("", true);
    picker.searchField().onChanged();
    assert(picker.filteredFamilies().length == initial.length,
        "clearing the filter did not restore the full list");
    assert(pickCount == activatedCount + 1,
        "clearing the filter must not fire a pick");

    writeln("fontpicker_smoke: ALL PASSED");
    window.close();
    return 0;
}

private final class WidgetTestRoot : Widget {}
