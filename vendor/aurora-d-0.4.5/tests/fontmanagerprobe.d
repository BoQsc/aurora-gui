module fontmanagerprobe;

import aurora.text.fontmanager : SystemFontInventory, InstalledFont, FontWeight;
import std.stdio : writeln, writefln;

int main()
{
    SystemFontInventory.rescan();
    auto fonts = SystemFontInventory.installed();
    writefln("total installed faces: %d", fonts.length);

    int families;
    string lastFamily;
    foreach (font; fonts)
    {
        if (font.familyName != lastFamily)
        {
            ++families;
            lastFamily = font.familyName;
        }
    }
    writefln("distinct families: %d", families);

    // Find Segoe UI and print its members.
    auto segoe = SystemFontInventory.familyMembers("Segoe UI");
    writefln("Segoe UI members: %d", segoe.length);
    foreach (member; segoe)
        writefln("  %s %s weight=%d italic=%d stretch=%d coverage=%d",
            member.subfamilyName, member.path, member.weight, member.italic,
            member.stretch, member.codepointCoverage);

    auto bold = SystemFontInventory.find("Segoe UI", FontWeight.bold);
    writefln("Segoe UI bold found: %d (first=%s)", bold.length,
        bold.length ? bold[0].path : "none");

    // CJK coverage: the best candidate for '中' should have large coverage.
    return 0;
}
