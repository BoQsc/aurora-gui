module auroraimageviewer_headless_smoke;

import aurora;
import auroraimageviewer.appui : ViewerRoot, imageViewerTheme;
import auroraimageviewer.decoder : DecodedImage, decodeImageFile;
import auroraimageviewer.imageview : ImageView;
import auroraimageviewer.scaler : MipImage;
import core.thread : Thread;
import core.time : msecs, seconds, MonoTime;
import std.algorithm : max, min;
import std.file : exists, getSize, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.math : abs;
import std.path : buildPath;
import std.stdio : stdout, writeln;
import std.zlib : compress, crc32;

private Widget findById(Widget root, string requestedId)
{
    if (root is null) return null;
    if (root.id() == requestedId) return root;
    foreach (child; root.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private Widget requireWidget(Widget root, string id)
{
    return findById(root, id);
}

// ---------------------------------------------------------------------------
// Test image writers (no external tools)
// ---------------------------------------------------------------------------

private void appendU16LE(ref ubyte[] buf, uint value)
{
    buf ~= cast(ubyte) (value & 0xffu);
    buf ~= cast(ubyte) ((value >> 8) & 0xffu);
}

private void appendI32LE(ref ubyte[] buf, int value)
{
    appendU32LE(buf, cast(uint) value);
}

private void appendU32LE(ref ubyte[] buf, uint value)
{
    buf ~= cast(ubyte) (value & 0xffu);
    buf ~= cast(ubyte) ((value >> 8) & 0xffu);
    buf ~= cast(ubyte) ((value >> 16) & 0xffu);
    buf ~= cast(ubyte) ((value >> 24) & 0xffu);
}

private void appendU32BE(ref ubyte[] buf, uint value)
{
    buf ~= cast(ubyte) ((value >> 24) & 0xffu);
    buf ~= cast(ubyte) ((value >> 16) & 0xffu);
    buf ~= cast(ubyte) ((value >> 8) & 0xffu);
    buf ~= cast(ubyte) (value & 0xffu);
}

private ubyte[] solidRgba(int width, int height, int r, int g, int b, int a = 255)
{
    ubyte[] pixels;
    pixels.length = cast(size_t) width * cast(size_t) height * 4;
    for (size_t index = 0; index < pixels.length; index += 4)
    {
        pixels[index] = cast(ubyte) r;
        pixels[index + 1] = cast(ubyte) g;
        pixels[index + 2] = cast(ubyte) b;
        pixels[index + 3] = cast(ubyte) a;
    }
    return pixels;
}

private ubyte[] pngChunk(string type, const(ubyte)[] data)
{
    ubyte[] buf;
    appendU32BE(buf, cast(uint) data.length);
    buf ~= cast(ubyte[]) type;
    buf ~= data;
    appendU32BE(buf, crc32(0, cast(ubyte[]) type ~ data));
    return buf;
}

private void writePng(string path, int width, int height, const(ubyte)[] rgba)
{
    const stride = width * 4;
    ubyte[] raw;
    raw.length = (cast(size_t) stride + 1) * cast(size_t) height;
    foreach (y; 0 .. height)
    {
        const row = cast(size_t) y * (cast(size_t) stride + 1);
        raw[row] = 0;
        raw[row + 1 .. row + 1 + stride] = rgba[cast(size_t) y * stride .. cast(size_t) (y + 1) * stride];
    }
    ubyte[] header;
    appendU32BE(header, cast(uint) width);
    appendU32BE(header, cast(uint) height);
    header ~= 8;  // bit depth
    header ~= 6;  // color type RGBA
    header ~= 0;  // compression
    header ~= 0;  // filter
    header ~= 0;  // interlace
    ubyte[] buf;
    buf ~= [137, 80, 78, 71, 13, 10, 26, 10];
    buf ~= pngChunk("IHDR", header);
    buf ~= pngChunk("IDAT", compress(raw));
    buf ~= pngChunk("IEND", []);
    write(path, buf);
}

private void writeBmp(string path, int width, int height, const(ubyte)[] rgba)
{
    const rowBytes = (cast(size_t) width * 3 + 3) / 4 * 4;
    ubyte[] buf;
    buf ~= 'B';
    buf ~= 'M';
    appendU32LE(buf, cast(uint) (14 + 40 + rowBytes * cast(size_t) height));
    appendU32LE(buf, 0);
    appendU32LE(buf, 14 + 40);
    appendU32LE(buf, 40);
    appendI32LE(buf, width);
    appendI32LE(buf, height);
    appendU16LE(buf, 1);
    appendU16LE(buf, 24);
    appendU32LE(buf, 0);
    appendU32LE(buf, cast(uint) (rowBytes * cast(size_t) height));
    appendI32LE(buf, 2835);
    appendI32LE(buf, 2835);
    appendU32LE(buf, 0);
    appendU32LE(buf, 0);
    foreach (y; 0 .. height)
    {
        const row = height - 1 - y;
        foreach (x; 0 .. width)
        {
            const o = (cast(size_t) row * cast(size_t) width + cast(size_t) x) * 4;
            buf ~= rgba[o + 2];
            buf ~= rgba[o + 1];
            buf ~= rgba[o];
        }
        foreach (_; 0 .. rowBytes - cast(size_t) width * 3)
            buf ~= 0;
    }
    write(path, buf);
}

private void writeTga(string path, int width, int height, const(ubyte)[] rgba)
{
    ubyte[] buf;
    buf ~= 0;      // id length
    buf ~= 0;      // color map type
    buf ~= 2;      // truecolor uncompressed
    buf ~= [0, 0, 0, 0, 0];
    buf ~= [0, 0];
    buf ~= [0, 0];
    appendU16LE(buf, cast(uint) width);
    appendU16LE(buf, cast(uint) height);
    buf ~= 32;     // depth
    buf ~= 0x20;   // top-down
    foreach (index; 0 .. cast(size_t) width * cast(size_t) height)
    {
        const o = index * 4;
        buf ~= rgba[o + 2];
        buf ~= rgba[o + 1];
        buf ~= rgba[o];
        buf ~= rgba[o + 3];
    }
    write(path, buf);
}

private void writePpm(string path, int width, int height, const(ubyte)[] rgba)
{
    ubyte[] buf;
    buf ~= cast(ubyte[]) ("P6\n" ~ format("%d %d\n255\n", width, height));
    foreach (index; 0 .. cast(size_t) width * cast(size_t) height)
    {
        const o = index * 4;
        buf ~= rgba[o];
        buf ~= rgba[o + 1];
        buf ~= rgba[o + 2];
    }
    write(path, buf);
}

private void writePam(string path, int width, int height, const(ubyte)[] rgba)
{
    ubyte[] buf;
    buf ~= cast(ubyte[]) ("P7\nWIDTH " ~ format("%d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        width, height));
    buf ~= rgba;
    write(path, buf);
}

private immutable ubyte[] tinyGif = [
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
    0x02, 0x00, 0x02, 0x00,
    0x80, 0x00, 0x00,
    0xff, 0x00, 0x00,
    0x00, 0x00, 0xff,
    0x2c, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00,
    0x02,
    0x03, 0x44, 0x82, 0x02,
    0x00,
    0x3b
];

// ---------------------------------------------------------------------------
// Scaler tests
// ---------------------------------------------------------------------------

private void testScaler()
{
    const int w = 64;
    const int h = 48;
    auto source = solidRgba(w, h, 30, 60, 90, 255);
    auto mip = new MipImage(w, h, source, false);
    assert(mip.width() == w && mip.height() == h);
    assert(mip.levelCount() == 4, format("expected 4 levels, got %d",
        mip.levelCount()));
    assert(mip.levelWidth(0) == 64 && mip.levelHeight(0) == 48);
    assert(mip.levelWidth(1) == 32 && mip.levelHeight(1) == 24);
    assert(mip.levelWidth(2) == 16 && mip.levelHeight(2) == 12);
    assert(mip.levelWidth(3) == 8 && mip.levelHeight(3) == 6);

    auto rgb = new ubyte[cast(size_t) w * cast(size_t) h * 3];
    const bg = Color.fromHex(0x111111);
    const ckA = Color.fromHex(0x444444);
    const ckB = Color.fromHex(0x222222);
    mip.render(rgb, w, h, 1.0, 0.0, 0.0, bg, ckA, ckB);
    foreach (index; 0 .. cast(size_t) w * cast(size_t) h)
    {
        const o = index * 3;
        assert(rgb[o] == 30 && rgb[o + 1] == 60 && rgb[o + 2] == 90,
            "100% render did not reproduce the source color");
    }

    auto small = new ubyte[cast(size_t) 32 * 24 * 3];
    mip.render(small, 32, 24, 0.5, 0.0, 0.0, bg, ckA, ckB);
    foreach (index; 0 .. 32 * 24)
    {
        const o = index * 3;
        assert(small[o] == 30 && small[o + 1] == 60 && small[o + 2] == 90,
            "50% render (mip level 1) did not keep the solid color");
    }

    const int bw = 16;
    const int bh = 12;
    auto block = solidRgba(bw, bh, 200, 100, 50, 255);
    auto smallBlock = new MipImage(bw, bh, block, false);
    auto letterboxed = new ubyte[cast(size_t) 32 * 24 * 3];
    smallBlock.render(letterboxed, 32, 24, 1.0, 0.0, 0.0, bg, ckA, ckB);
    assert(letterboxed[0] == 200 && letterboxed[1] == 100 && letterboxed[2] == 50);
    const index = (20 * 32 + 30) * 3;
    assert(letterboxed[index] == 0x11 && letterboxed[index + 1] == 0x11 &&
        letterboxed[index + 2] == 0x11, "letterbox area was not the background");

    auto negativeOffset = new ubyte[cast(size_t) 24 * 12 * 3];
    smallBlock.render(negativeOffset, 24, 12, 1.0, -8.0, 0.0, bg, ckA, ckB);
    const leftPx = (6 * 24 + 0) * 3;
    assert(negativeOffset[leftPx] == 0x11, "left letterbox should be background");
    const imgPx = (6 * 24 + 8) * 3;
    assert(negativeOffset[imgPx] == 200 && negativeOffset[imgPx + 1] == 100 &&
        negativeOffset[imgPx + 2] == 50, "offset render did not sample the image");

    auto alphaPixels = solidRgba(bw, bh, 255, 0, 0, 255);
    foreach (y; 4 .. 8)
        foreach (x; 4 .. 8)
        {
            const o = (cast(size_t) y * cast(size_t) bw + cast(size_t) x) * 4;
            alphaPixels[o + 3] = 128;
        }
    alphaPixels[(7 * bw + 2) * 4 + 3] = 0;
    auto alphaMip = new MipImage(bw, bh, alphaPixels, true);
    auto alphaOut = new ubyte[cast(size_t) bw * cast(size_t) bh * 3];
    alphaMip.render(alphaOut, bw, bh, 1.0, 0.0, 0.0, bg, ckA, ckB);
    const opaquePx = (0 * bw + 0) * 3;
    assert(alphaOut[opaquePx] == 255 && alphaOut[opaquePx + 1] == 0 &&
        alphaOut[opaquePx + 2] == 0, "opaque pixel was not kept opaque");
    const semiPx = (4 * bw + 4) * 3;
    const expectedR = (255u * 128u + 0x44u * 127u + 127u) / 255u;
    assert(alphaOut[semiPx] == cast(ubyte) expectedR,
        format("semi-transparent pixel blended over the wrong checker (got %d)",
            alphaOut[semiPx]));
    const clearPx = (7 * bw + 2) * 3;
    assert(alphaOut[clearPx] == 0x44, "fully transparent pixel did not show the checker");

    writeln("Scaler tests passed.");
    stdout.flush();
}

// ---------------------------------------------------------------------------
// Decoding tests
// ---------------------------------------------------------------------------

private void testDecoding(string directory)
{
    const pngPath = buildPath(directory, "opaque.png");
    writePng(pngPath, 64, 48, solidRgba(64, 48, 30, 60, 90, 255));
    auto png = decodeImageFile(pngPath);
    assert(png.width == 64 && png.height == 48);
    assert(!png.hasAlpha, "opaque PNG reported alpha");
    assert(png.rgba.length == 64 * 48 * 4);
    assert(png.format == "PNG");
    assert(png.rgba[0] == 30 && png.rgba[1] == 60 && png.rgba[2] == 90);

    const alphaPath = buildPath(directory, "alpha.png");
    auto alphaPixels = solidRgba(16, 12, 255, 0, 0, 255);
    alphaPixels[(5 * 16 + 5) * 4 + 3] = 0;
    writePng(alphaPath, 16, 12, alphaPixels);
    auto alpha = decodeImageFile(alphaPath);
    assert(alpha.width == 16 && alpha.height == 12);
    assert(alpha.hasAlpha, "transparent PNG did not report alpha");
    assert(alpha.rgba[(5 * 16 + 5) * 4 + 3] == 0, "transparent pixel lost");

    const bmpPath = buildPath(directory, "test.bmp");
    writeBmp(bmpPath, 30, 20, solidRgba(30, 20, 10, 200, 90));
    auto bmp = decodeImageFile(bmpPath);
    assert(bmp.width == 30 && bmp.height == 20, "BMP dimensions wrong");
    assert(!bmp.hasAlpha, "24-bit BMP reported alpha");
    assert(bmp.rgba[0] == 10 && bmp.rgba[1] == 200 && bmp.rgba[2] == 90,
        "BMP color wrong");

    const tgaPath = buildPath(directory, "test.tga");
    auto tgaPixels = solidRgba(8, 6, 255, 0, 0, 255);
    tgaPixels[(2 * 8 + 2) * 4 + 3] = 128;
    writeTga(tgaPath, 8, 6, tgaPixels);
    auto tga = decodeImageFile(tgaPath);
    assert(tga.width == 8 && tga.height == 6, "TGA dimensions wrong");
    assert(tga.hasAlpha, "TGA with transparency did not report alpha");
    assert(tga.rgba[(2 * 8 + 2) * 4 + 3] == 128, "TGA alpha wrong");
    assert(tga.rgba[0] == 255 && tga.rgba[1] == 0 && tga.rgba[2] == 0,
        "TGA color wrong");

    const ppmPath = buildPath(directory, "test.ppm");
    writePpm(ppmPath, 16, 10, solidRgba(16, 10, 5, 250, 128));
    auto ppm = decodeImageFile(ppmPath);
    assert(ppm.width == 16 && ppm.height == 10, "PPM dimensions wrong");
    assert(ppm.rgba[0] == 5 && ppm.rgba[1] == 250 && ppm.rgba[2] == 128,
        "PPM color wrong");

    const pamPath = buildPath(directory, "test.pam");
    auto pamPixels = solidRgba(8, 8, 12, 34, 56, 255);
    pamPixels[(3 * 8 + 3) * 4 + 3] = 77;
    writePam(pamPath, 8, 8, pamPixels);
    auto pam = decodeImageFile(pamPath);
    assert(pam.width == 8 && pam.height == 8, "PAM dimensions wrong");
    assert(pam.hasAlpha, "PAM depth 4 did not report alpha");
    assert(pam.rgba[(3 * 8 + 3) * 4 + 3] == 77, "PAM alpha wrong");

    const gifPath = buildPath(directory, "test.gif");
    write(gifPath, tinyGif);
    auto gif = decodeImageFile(gifPath);
    assert(gif.width == 2 && gif.height == 2, "GIF dimensions wrong");
    assert(gif.rgba[0] == 0xff && gif.rgba[1] == 0 && gif.rgba[2] == 0,
        "GIF pixel 0 wrong");
    assert(gif.rgba[(0 * 2 + 1) * 4 + 0] == 0 &&
        gif.rgba[(0 * 2 + 1) * 4 + 2] == 0xff, "GIF pixel 1 wrong");
    assert(gif.rgba[(1 * 2 + 0) * 4 + 0] == 0 &&
        gif.rgba[(1 * 2 + 0) * 4 + 2] == 0xff, "GIF pixel 2 wrong");
    assert(gif.rgba[(1 * 2 + 1) * 4 + 0] == 0xff, "GIF pixel 3 wrong");

    writeln("Decoding tests passed.");
    stdout.flush();
}

// ---------------------------------------------------------------------------
// UI tests
// ---------------------------------------------------------------------------

private bool waitForLoad(ViewerRoot root, UiTestDriver driver)
{
    const deadline = MonoTime.currTime + seconds(60);
    while (MonoTime.currTime < deadline && !root.imageLoadedForTesting())
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
        driver.paint();
    }
    return root.imageLoadedForTesting();
}

private void testUi(string directory)
{
    const pngPath = buildPath(directory, "opaque.png");
    const bmpPath = buildPath(directory, "test.bmp");

    WindowOptions options;
    options.title = "Aurora Image Viewer headless";
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, imageViewerTheme());
    auto root = new ViewerRoot(window, pngPath);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "Initial paint failed");
    root.tickTree(0.02);

    assert(waitForLoad(root, driver), "PNG did not load: " ~ root.statusTextForTesting());
    auto view = root.viewForTesting();
    assert(view !is null);
    assert(view.imageWidth() == 64 && view.imageHeight() == 48);
    const fitZoom = view.zoom();
    assert(fitZoom > 0.0);

    assert(requireWidget(root, "iv-zoom") !is null, "zoom label not found");

    const center = view.localToGlobal(Point(view.bounds().width / 2,
        view.bounds().height / 2));

    driver.wheel(center, 3);
    root.tickTree(0.02);
    assert(driver.paint(), "Zoom-in paint failed");
    assert(view.zoom() > fitZoom, "wheel zoom in did not increase zoom");

    driver.wheel(center, -6);
    root.tickTree(0.02);
    assert(driver.paint(), "Zoom-out paint failed");
    assert(view.zoom() < fitZoom, "wheel zoom out did not decrease zoom");

    view.fitToWindow();
    assert(driver.paint(), "Fit paint failed");
    const expectedFit = min(view.bounds().width / 64.0,
        view.bounds().height / 48.0);
    assert((view.zoom() - expectedFit).abs < 0.01, "fit zoom mismatch");

    const from = view.localToGlobal(Point(40, 40));
    const to = view.localToGlobal(Point(140, 90));
    const offsetBefore = view.offsetX();
    driver.drag(from, to, 6);
    root.tickTree(0.02);
    assert(driver.paint(), "Drag paint failed");
    assert((view.offsetX() - offsetBefore).abs > 0.001, "drag did not pan");

    driver.dropFiles(center, [bmpPath]);
    const dropDeadline = MonoTime.currTime + seconds(60);
    while (MonoTime.currTime < dropDeadline &&
        !(view.imageWidth() == 30 && view.imageHeight() == 20))
    {
        root.tickTree(0.02);
        Thread.sleep(10.msecs);
        driver.paint();
    }
    assert(view.imageWidth() == 30 && view.imageHeight() == 20,
        "Dropped image dimensions wrong");

    driver.pressKey(Key.digit1);
    root.tickTree(0.02);
    assert(driver.paint(), "Actual size paint failed");
    assert((view.zoom() - 1.0).abs < 0.001, "digit1 did not set actual size");

    const ppmPath = buildPath(directory, "viewer.ppm");
    window.saveScreenshot(ppmPath);
    assert(exists(ppmPath), "Screenshot was not written");
    assert(getSize(ppmPath) > 1000, "Screenshot is too small");

    window.close();
    writeln("UI tests passed.");
    stdout.flush();
}

// ---------------------------------------------------------------------------

int main()
{
    const directory = buildPath(tempDir(), "aurora-image-viewer-smoke");
    if (exists(directory)) rmdirRecurse(directory);
    mkdirRecurse(directory);

    testScaler();
    testDecoding(directory);
    testUi(directory);

    writeln("Aurora Image Viewer headless smoke test passed.");
    return 0;
}


