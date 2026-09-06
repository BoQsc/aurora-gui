module tests.cursorsheet;

import aurora;
import aurora.pointer;
import std.stdio : writeln;

int main()
{
    CursorKind[9] kinds = [CursorKind.arrow, CursorKind.hand, CursorKind.text,
        CursorKind.resizeHorizontal, CursorKind.resizeVertical,
        CursorKind.resizeDiagonalNWSE, CursorKind.resizeDiagonalNESW,
        CursorKind.move, CursorKind.forbidden];
    auto sheet = new Surface(40 * 9 + 10 * 8, 40);
    sheet.clear(Color.rgb(30, 60, 90));
    foreach (index, kind; kinds)
    {
        auto cell = Canvas(sheet).translated(cast(int) (index * 50), 0);
        auto clipped = cell.clipped(Rect(0, 0, 40, 40));
        drawSystemCursor(clipped, kind);
    }
    sheet.savePpm("build/cursor-sheet.ppm");
    writeln("saved");
    return 0;
}
