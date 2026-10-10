// Focused verification for the transcript height fix: a virtualized (>80 row)
// TranscriptPresenter must report its height as the sum of the rows' real
// heights, not a fixed 64px placeholder for rows that were never measured.
module tpresenter_check;

import aurora;
import auroraopencode.transcriptpresenter : TranscriptPresenter, DeferredTranscriptRow;
import std.stdio : writeln;

private final class RowBox : Widget
{
    private int _h;
    this(int h) { _h = h; }
    protected override Size onMeasure(Size available)
    {
        return Size(available.width, _h);
    }
}

int main()
{
    // A long message path can project fewer than 80 visible rows. Its deferred
    // descriptors must occupy their measured height in the ordinary VBox path.
    foreach (count; [12, 100])
    {
        auto column = new TranscriptPresenter(6, Insets(0));
        foreach (i; 0 .. count)
            column.add(new DeferredTranscriptRow(() => new RowBox(30)));
        auto viewport = new ScrollView(column);
        viewport.setBounds(Rect(0, 0, 800, 300));
        viewport.layoutTree();
        int bottom;
        foreach (row; column.children())
        {
            assert(row.bounds().height == 30, "Deferred row was measured but collapsed during layout");
            assert(row.bounds().y >= bottom, "Deferred rows overlap");
            bottom = row.bounds().bottom();
        }
        assert(viewport.contentHeight() - bottom <= 6,
            "Scrollbar extends beyond the laid-out rows");
    }
    auto presenter = new TranscriptPresenter(0, Insets(0));
    enum int rows = 100;
    enum int rowH = 30;
    foreach (i; 0 .. rows)
        presenter.add(new RowBox(rowH));

    auto view = new ScrollView(presenter);
    view.setBounds(Rect(0, 0, 800, 300));
    view.layoutTree();

    const content = view.contentHeight();
    const expected = rows * rowH;
    writeln("contentHeight=", content, " expected=", expected);
    if (content != expected)
    {
        writeln("FAIL: unmeasured rows still inflate the transcript height");
        return 1;
    }
    writeln("tpresenter_check: OK");
    return 0;
}
