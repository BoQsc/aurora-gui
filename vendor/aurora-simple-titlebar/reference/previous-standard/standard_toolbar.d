module aurora.widgets.standard_toolbar;

import aurora.widgets.button : Button;
import aurora.widgets.label : Label;
import aurora.layout : HBox, Spacer;
import aurora.widget : Widget;
import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.types : Rect, Size, Insets, HorizontalAlign, VerticalAlign, maxInt;
import aurora.icons : IconKind;
import aurora.theme : Theme;

/**
 * StandardToolbar — distilled vendor standard.
 * Moved into vendor/aurora-d-0.4.5/source/aurora/widgets/ per project policy:
 * all Aurora apps share this via `../vendor/aurora-d-0.4.5/source` (no separate top-level lib).
 *
 * Distilled from:
 *   aurora-cut/editor.d:1141        HBox(4,Insets(6,3)) h=32 bg 0x20242a
 *   aurora-browser/appui.d:855      HBox(6,Insets(8,6)) h=48
 *   aurora-opencode/appui.d:394     HBox(8,Insets(10,6)) h=52
 *   aurora-opencode-pro/appui.d:1312  +ContextUsageBadge 56x22
 *   aurora-designer/appui.d:162     HBox(4,Insets(6,2)) h=38
 *   aurora-image-viewer/appui.d:84  HBox(6,Insets(8,6)) h=48 border
 */
enum StandardToolbarPreset : ubyte { standard, cut, designer, browser, opencode }

final class StandardUsageBadge : Widget
{
    void delegate(bool open) onHoverChanged;
    private int _prompt = -1, _completion = -1, _total = -1;
    private int _limit = 128_000;
    this() { layoutHints().preferredWidth = 56; layoutHints().minWidth = 56; layoutHints().preferredHeight = 22; }
    void setModel(string model) { const l = contextLimitForModel(model); if (l == _limit) return; _limit = l; invalidate(); }
    void setUsage(int p,int c,int t){ if(p==_prompt&&c==_completion&&t==_total) return; _prompt=p; _completion=c; _total=t; invalidate(); }
    int promptTokens() const @safe pure nothrow @nogc { return _prompt; }
    int completionTokens() const @safe pure nothrow @nogc { return _completion; }
    int totalTokens() const @safe pure nothrow @nogc { return _total; }
    int limit() const @safe pure nothrow @nogc { return _limit; }
    bool hasUsage() const @safe pure nothrow @nogc { return _total>0 && _limit>0; }
    int usagePercent() const { if(_total<=0||_limit<=0) return 0; const long s=(cast(long)_total*100+_limit-1)/_limit; return s>=100?100:cast(int)s; }
    string labelForTesting(){ return hasUsage()? toStr(usagePercent)~"%" : "ctx"; }
    protected override Size onMeasure(Size a){ layoutHints().preferredWidth=56; layoutHints().preferredHeight=22; return Size(56,22); }
    protected override void onPaint(ref Canvas canvas)
    {
        const w=bounds.width, h=bounds.height;
        canvas.fillRoundedRect(Rect(0,0,w,h), h/2, Color.fromHex(0x2b333d));
        if(hasUsage()){ const pct=usagePercent(); const fw=maxInt(1,(w-4)*pct/100);
            canvas.fillRoundedRect(Rect(2,2,fw,h-4),(h-4)/2,pct>=90?Color.fromHex(0xe5484d):Color.fromHex(0x5a8ef0)); }
        import std.utf: toUTF32; canvas.drawTextInRect(Rect(0,0,w,h), toUTF32(labelForTesting()), hasUsage()?theme().text:Color.fromHex(0x9ba7b5), 1, HorizontalAlign.center, VerticalAlign.middle, true);
    }
    protected override void onMouseEnter(){ if(onHoverChanged!is null) onHoverChanged(true); }
    protected override void onMouseLeave(){ if(onHoverChanged!is null) onHoverChanged(false); }
}
private int contextLimitForModel(string m)
{
    import std.string: toLower, indexOf;
    auto l=m.toLower();
    if(l.indexOf("gpt-4")>=0) return 128_000;
    if(l.indexOf("claude")>=0) return 200_000;
    return 128_000;
}
private string toStr(T)(T v){ import std.conv : to; return to!string(v); }

private int spacingOf(StandardToolbarPreset p) @safe pure nothrow @nogc
{
    final switch (p)
    {
        case StandardToolbarPreset.standard: return 8;
        case StandardToolbarPreset.cut: return 4;
        case StandardToolbarPreset.designer: return 4;
        case StandardToolbarPreset.browser: return 6;
        case StandardToolbarPreset.opencode: return 8;
    }
}
private Insets paddingOf(StandardToolbarPreset p) @safe pure nothrow @nogc
{
    final switch (p)
    {
        case StandardToolbarPreset.standard: return Insets(10, 6);
        case StandardToolbarPreset.cut: return Insets(6, 3);
        case StandardToolbarPreset.designer: return Insets(6, 2);
        case StandardToolbarPreset.browser: return Insets(8, 6);
        case StandardToolbarPreset.opencode: return Insets(10, 6);
    }
}
private int heightOf(StandardToolbarPreset p) @safe pure nothrow @nogc
{
    final switch (p)
    {
        case StandardToolbarPreset.standard: return 48;
        case StandardToolbarPreset.cut: return 32;
        case StandardToolbarPreset.designer: return 38;
        case StandardToolbarPreset.browser: return 48;
        case StandardToolbarPreset.opencode: return 52;
    }
}

final class StandardToolbar : HBox
{
    private StandardToolbarPreset _preset;
    this(StandardToolbarPreset preset = StandardToolbarPreset.standard)
    {
        super(spacingOf(preset), paddingOf(preset));
        _preset = preset;
        layoutHints().preferredHeight = heightOf(preset);
        if (preset == StandardToolbarPreset.cut)
            setBackground(Color.fromHex(0x20242a));
        setId("standard-toolbar");
    }

    Button addButton(string text, IconKind icon = IconKind.none, string id = "")
    {
        auto b = add(new Button(text, icon));
        if (id.length) b.setId(id);
        b.layoutHints().preferredHeight = 26;
        return b;
    }
    Label addLabel(string text, int scale = 1, uint colorHex = 0)
    {
        auto l = add(new Label(text));
        l.setScale(scale);
        if (colorHex != 0) l.setColor(Color.fromHex(colorHex));
        l.layoutHints().preferredHeight = 26;
        return l;
    }
    Spacer addSpacer() { return add(new Spacer()); }

    Button addNavButton(string id, IconKind icon, void delegate() cb)
    {
        auto b = addButton("", icon, id);
        b.setIconSize(16);
        b.layoutHints().preferredWidth = 36;
        b.onClick = cb;
        return b;
    }
}

unittest
{
    auto tb = new StandardToolbar(StandardToolbarPreset.standard);
    assert(tb.layoutHints().preferredHeight == 48);
    auto cut = new StandardToolbar(StandardToolbarPreset.cut);
    assert(cut.layoutHints().preferredHeight == 32);
    auto des = new StandardToolbar(StandardToolbarPreset.designer);
    assert(des.layoutHints().preferredHeight == 38);
    auto op = new StandardToolbar(StandardToolbarPreset.opencode);
    assert(op.layoutHints().preferredHeight == 52);
    auto badge = new StandardUsageBadge();
    assert(badge.labelForTesting() == "ctx");
    badge.setUsage(1000, 500, 1500);
    assert(badge.hasUsage());
    assert(badge.usagePercent() == 2);
}
