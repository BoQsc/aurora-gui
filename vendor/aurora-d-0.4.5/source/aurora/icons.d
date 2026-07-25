module aurora.icons;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.types : Point, Rect, maxInt;

enum IconKind : ubyte
{
    none,
    file,
    folder,
    home,
    computer,
    notepad,
    trash,
    save,
    open,
    newDocument,
    up,
    refresh,
    search,
    start,
    close,
    minimize,
    maximize,
    clock,
    settings,
    terminal,
    image,
    music,
    drive,
    chevronRight,
    chevronDown
}

void drawIcon(ref Canvas canvas, IconKind icon, Rect rect, Color foreground,
    Color accent = Color.fromHex(0x4f8cff))
{
    const scale = maxInt(1, rect.width / 18);
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    final switch (icon)
    {
        case IconKind.none:
            break;
        case IconKind.file:
        case IconKind.newDocument:
        {
            auto page = Rect(cx - 7 * scale, cy - 9 * scale, 14 * scale, 18 * scale);
            canvas.drawRoundedRect(page, 2 * scale, foreground.withAlpha(35), foreground, scale);
            canvas.drawLine(Point(page.right() - 5 * scale, page.y),
                Point(page.right(), page.y + 5 * scale), foreground, scale);
            canvas.drawLine(Point(page.right() - 5 * scale, page.y),
                Point(page.right() - 5 * scale, page.y + 5 * scale), foreground, scale);
            if (icon == IconKind.newDocument)
            {
                canvas.drawLine(Point(cx, cy - 2 * scale), Point(cx, cy + 5 * scale), accent, scale * 2);
                canvas.drawLine(Point(cx - 4 * scale, cy + 1 * scale), Point(cx + 4 * scale, cy + 1 * scale), accent, scale * 2);
            }
            break;
        }
        case IconKind.folder:
        case IconKind.open:
        {
            auto body = Rect(cx - 9 * scale, cy - 5 * scale, 18 * scale, 13 * scale);
            canvas.fillRoundedRect(body, 2 * scale, accent);
            canvas.fillRoundedRect(Rect(body.x + 1 * scale, body.y - 4 * scale, 8 * scale, 6 * scale),
                2 * scale, accent.lighter(22));
            canvas.strokeRect(body, foreground.withAlpha(100), scale);
            if (icon == IconKind.open)
                canvas.drawLine(Point(cx - 3 * scale, cy + 1 * scale), Point(cx + 6 * scale, cy - 5 * scale), foreground, scale);
            break;
        }
        case IconKind.home:
        {
            canvas.drawLine(Point(cx - 9 * scale, cy), Point(cx, cy - 8 * scale), foreground, scale * 2);
            canvas.drawLine(Point(cx, cy - 8 * scale), Point(cx + 9 * scale, cy), foreground, scale * 2);
            canvas.drawRoundedRect(Rect(cx - 7 * scale, cy, 14 * scale, 9 * scale), 2 * scale,
                accent.withAlpha(130), foreground, scale);
            break;
        }
        case IconKind.computer:
        {
            canvas.drawRoundedRect(Rect(cx - 10 * scale, cy - 8 * scale, 20 * scale, 14 * scale),
                2 * scale, accent.withAlpha(150), foreground, scale);
            canvas.fillRect(Rect(cx - 2 * scale, cy + 6 * scale, 4 * scale, 3 * scale), foreground);
            canvas.fillRect(Rect(cx - 6 * scale, cy + 9 * scale, 12 * scale, scale), foreground);
            break;
        }
        case IconKind.notepad:
        {
            canvas.drawRoundedRect(Rect(cx - 8 * scale, cy - 9 * scale, 16 * scale, 18 * scale),
                2 * scale, Color.fromHex(0xfff1a8), foreground, scale);
            foreach (i; 0 .. 3)
                canvas.drawLine(Point(cx - 5 * scale, cy - 3 * scale + i * 4 * scale),
                    Point(cx + 5 * scale, cy - 3 * scale + i * 4 * scale), foreground.withAlpha(150), scale);
            break;
        }
        case IconKind.trash:
        {
            canvas.drawRoundedRect(Rect(cx - 6 * scale, cy - 5 * scale, 12 * scale, 13 * scale),
                2 * scale, foreground.withAlpha(35), foreground, scale);
            canvas.fillRect(Rect(cx - 8 * scale, cy - 8 * scale, 16 * scale, 2 * scale), foreground);
            canvas.fillRect(Rect(cx - 3 * scale, cy - 10 * scale, 6 * scale, 2 * scale), foreground);
            break;
        }
        case IconKind.save:
        {
            canvas.drawRoundedRect(Rect(cx - 9 * scale, cy - 9 * scale, 18 * scale, 18 * scale),
                2 * scale, accent, foreground, scale);
            canvas.fillRect(Rect(cx - 5 * scale, cy - 7 * scale, 8 * scale, 5 * scale), foreground.withAlpha(210));
            canvas.fillRoundedRect(Rect(cx - 5 * scale, cy + 1 * scale, 10 * scale, 6 * scale), scale, foreground.withAlpha(220));
            break;
        }
        case IconKind.up:
            canvas.drawLine(Point(cx - 7 * scale, cy + 3 * scale), Point(cx, cy - 4 * scale), foreground, scale * 2);
            canvas.drawLine(Point(cx, cy - 4 * scale), Point(cx + 7 * scale, cy + 3 * scale), foreground, scale * 2);
            break;
        case IconKind.refresh:
            canvas.strokeCircle(Point(cx, cy), 7 * scale, foreground, scale * 2);
            canvas.fillRect(Rect(cx + 3 * scale, cy - 8 * scale, 6 * scale, 5 * scale), accent);
            break;
        case IconKind.search:
            canvas.strokeCircle(Point(cx - 2 * scale, cy - 2 * scale), 6 * scale, foreground, scale * 2);
            canvas.drawLine(Point(cx + 3 * scale, cy + 3 * scale), Point(cx + 9 * scale, cy + 9 * scale), foreground, scale * 2);
            break;
        case IconKind.start:
        {
            const tile = 6 * scale;
            canvas.fillRect(Rect(cx - 7 * scale, cy - 7 * scale, tile, tile), foreground);
            canvas.fillRect(Rect(cx + scale, cy - 7 * scale, tile, tile), foreground);
            canvas.fillRect(Rect(cx - 7 * scale, cy + scale, tile, tile), foreground);
            canvas.fillRect(Rect(cx + scale, cy + scale, tile, tile), foreground);
            break;
        }
        case IconKind.close:
            canvas.drawLine(Point(cx - 6 * scale, cy - 6 * scale), Point(cx + 6 * scale, cy + 6 * scale), foreground, scale * 2);
            canvas.drawLine(Point(cx + 6 * scale, cy - 6 * scale), Point(cx - 6 * scale, cy + 6 * scale), foreground, scale * 2);
            break;
        case IconKind.minimize:
            canvas.fillRect(Rect(cx - 7 * scale, cy + 4 * scale, 14 * scale, scale * 2), foreground);
            break;
        case IconKind.maximize:
            canvas.strokeRect(Rect(cx - 7 * scale, cy - 7 * scale, 14 * scale, 14 * scale), foreground, scale * 2);
            break;
        case IconKind.clock:
            canvas.strokeCircle(Point(cx, cy), 8 * scale, foreground, scale);
            canvas.drawLine(Point(cx, cy), Point(cx, cy - 5 * scale), foreground, scale);
            canvas.drawLine(Point(cx, cy), Point(cx + 4 * scale, cy + 2 * scale), foreground, scale);
            break;
        case IconKind.settings:
        {
            canvas.strokeCircle(Point(cx, cy), 7 * scale, foreground, scale * 3);
            canvas.fillCircle(Point(cx, cy), 2 * scale, accent);
            foreach (angle; 0 .. 4)
            {
                if ((angle & 1) == 0)
                    canvas.fillRect(Rect(cx - scale, cy - 11 * scale + angle / 2 * 20 * scale, 2 * scale, 5 * scale), foreground);
                else
                    canvas.fillRect(Rect(cx - 11 * scale + angle / 2 * 20 * scale, cy - scale, 5 * scale, 2 * scale), foreground);
            }
            break;
        }
        case IconKind.terminal:
            canvas.drawRoundedRect(Rect(cx - 10 * scale, cy - 8 * scale, 20 * scale, 16 * scale),
                2 * scale, Color.fromHex(0x17202a), foreground, scale);
            canvas.drawLine(Point(cx - 6 * scale, cy - 3 * scale), Point(cx - 2 * scale, cy), accent, scale);
            canvas.drawLine(Point(cx - 2 * scale, cy), Point(cx - 6 * scale, cy + 3 * scale), accent, scale);
            canvas.fillRect(Rect(cx, cy + 3 * scale, 6 * scale, scale), foreground);
            break;
        case IconKind.image:
            canvas.drawRoundedRect(Rect(cx - 9 * scale, cy - 8 * scale, 18 * scale, 16 * scale),
                2 * scale, accent.withAlpha(70), foreground, scale);
            canvas.fillCircle(Point(cx + 4 * scale, cy - 3 * scale), 2 * scale, foreground);
            canvas.drawLine(Point(cx - 7 * scale, cy + 5 * scale), Point(cx - 1 * scale, cy - 1 * scale), foreground, scale);
            canvas.drawLine(Point(cx - 1 * scale, cy - 1 * scale), Point(cx + 7 * scale, cy + 5 * scale), foreground, scale);
            break;
        case IconKind.music:
            canvas.drawLine(Point(cx + 4 * scale, cy - 8 * scale), Point(cx + 4 * scale, cy + 4 * scale), foreground, scale * 2);
            canvas.drawLine(Point(cx + 4 * scale, cy - 8 * scale), Point(cx - 5 * scale, cy - 5 * scale), foreground, scale * 2);
            canvas.fillCircle(Point(cx + scale, cy + 6 * scale), 4 * scale, accent);
            canvas.fillCircle(Point(cx - 8 * scale, cy + 2 * scale), 4 * scale, accent);
            canvas.drawLine(Point(cx - 5 * scale, cy - 5 * scale), Point(cx - 5 * scale, cy), foreground, scale * 2);
            break;
        case IconKind.drive:
            canvas.drawRoundedRect(Rect(cx - 10 * scale, cy - 5 * scale, 20 * scale, 11 * scale),
                3 * scale, foreground.withAlpha(30), foreground, scale);
            canvas.fillCircle(Point(cx + 6 * scale, cy + 1 * scale), scale, accent);
            break;
        case IconKind.chevronRight:
            canvas.drawLine(Point(cx - 3 * scale, cy - 6 * scale), Point(cx + 3 * scale, cy), foreground, scale * 2);
            canvas.drawLine(Point(cx + 3 * scale, cy), Point(cx - 3 * scale, cy + 6 * scale), foreground, scale * 2);
            break;
        case IconKind.chevronDown:
            canvas.drawLine(Point(cx - 6 * scale, cy - 3 * scale), Point(cx, cy + 3 * scale), foreground, scale * 2);
            canvas.drawLine(Point(cx, cy + 3 * scale), Point(cx + 6 * scale, cy - 3 * scale), foreground, scale * 2);
            break;
    }
}
