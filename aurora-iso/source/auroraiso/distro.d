/**
 * Catalog of official Linux distribution images.
 *
 * Only first-party release servers are listed (Canonical's
 * releases.ubuntu.com and Fedora's download.fedoraproject.org). Entries are
 * pinned to concrete official file names so the download is unambiguous; the
 * URLs are verified against the vendor index listings.
 *
 * Update procedure: open the vendor index (e.g.
 * https://releases.ubuntu.com/<release>/ or
 * https://download.fedoraproject.org/pub/fedora/linux/releases/<n>/.../iso/)
 * and refresh the version and file name below.
 */
module auroraiso.distro;

import std.array : appender;
import std.string : startsWith;

/// One downloadable official distribution image.
struct DistroImage
{
    string vendor;      // "Ubuntu" or "Fedora"
    string name;        // human readable title
    string edition;     // "Desktop", "Server", "Workstation", ...
    string url;         // official download URL
    ulong approxBytes;  // rough size for the UI (0 when unknown)
    string sha256;      // vendor-published checksum when known ("" otherwise)

    string secondaryText() const
    {
        return vendor ~ " · " ~ edition;
    }
}

/// The complete list of official images this build knows about.
DistroImage[] officialImages()
{
    return [
        // ---- Ubuntu (releases.ubuntu.com) ----
        DistroImage("Ubuntu", "Ubuntu 26.04.1 LTS \"Resolute Raccoon\" Desktop",
            "Desktop (amd64)", "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-desktop-amd64.iso",
            6442450944UL, ""),
        DistroImage("Ubuntu", "Ubuntu 26.04.1 LTS \"Resolute Raccoon\" Server",
            "Server (amd64)", "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.iso",
            2899102925UL, ""),
        DistroImage("Ubuntu", "Ubuntu 24.04.5 LTS \"Noble Numbat\" Desktop",
            "Desktop (amd64)", "https://releases.ubuntu.com/24.04/ubuntu-24.04.5.1-desktop-amd64.iso",
            6227702579UL, ""),
        DistroImage("Ubuntu", "Ubuntu 24.04.5 LTS \"Noble Numbat\" Server",
            "Server (amd64)", "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso",
            4080218931UL, ""),
        DistroImage("Ubuntu", "Ubuntu 22.04.5 LTS \"Jammy Jellyfish\" Desktop",
            "Desktop (amd64)", "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso",
            4724464026UL, ""),
        DistroImage("Ubuntu", "Ubuntu 22.04.5 LTS \"Jammy Jellyfish\" Server",
            "Server (amd64)", "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso",
            2147483648UL, ""),

        // ---- Fedora (download.fedoraproject.org) ----
        DistroImage("Fedora", "Fedora Workstation 44",
            "Workstation (x86_64)",
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/x86_64/iso/Fedora-Workstation-Live-44-1.7.x86_64.iso",
            2851612672UL,
            "1620295f6a00c27c3208f0c00b8ece4eab1ec69b9002152d97488bf26a426ddf"),
        DistroImage("Fedora", "Fedora Server 44",
            "Server DVD (x86_64)",
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Server/x86_64/iso/Fedora-Server-dvd-x86_64-44-1.7.iso",
            3908420239UL, ""),
        DistroImage("Fedora", "Fedora Server 44 (netinstall)",
            "Server netinst (x86_64)",
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Server/x86_64/iso/Fedora-Server-netinst-x86_64-44-1.7.iso",
            1224065679UL, ""),
    ];
}

/// Images from a single vendor, preserving catalog order.
DistroImage[] imagesForVendor(string vendor)
{
    DistroImage[] result;
    foreach (image; officialImages())
        if (image.vendor == vendor)
            result ~= image;
    return result;
}

/// The vendors present in the catalog, in first-seen order.
string[] vendors()
{
    string[] result;
    foreach (image; officialImages())
    {
        bool seen;
        foreach (existing; result)
            if (existing == image.vendor)
                seen = true;
        if (!seen)
            result ~= image.vendor;
    }
    return result;
}

unittest
{
    auto images = officialImages();
    assert(images.length >= 6);

    foreach (image; images)
    {
        assert(image.url.startsWith("https://"));
        assert(image.vendor.length > 0);
        assert(image.name.length > 0);
    }

    // No duplicate URLs.
    foreach (i; 0 .. images.length)
        foreach (j; i + 1 .. images.length)
            assert(images[i].url != images[j].url);

    auto ubuntu = imagesForVendor("Ubuntu");
    auto fedora = imagesForVendor("Fedora");
    assert(ubuntu.length == 6);
    assert(fedora.length == 3);
    assert(ubuntu[0].edition == "Desktop (amd64)");

    auto seenVendors = vendors();
    assert(seenVendors.length == 2);
    assert(seenVendors[0] == "Ubuntu");
    assert(seenVendors[1] == "Fedora");
}
