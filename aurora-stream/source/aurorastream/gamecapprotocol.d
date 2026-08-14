module aurorastream.gamecapprotocol;

/// Versioned wire format shared by the injected D3D11 hook and Aurora Stream.
/// Both sides are x64 Windows processes and exchange native little-endian
/// values. The pipe carries only fixed-size control/frame headers; BGRA8 pixels
/// live in a bounded shared-memory ring so multi-megabyte frames never traverse
/// the named pipe.
enum uint gameCaptureMagic = 0x41554346; // "AUCF"
enum uint gameCaptureProtocolVersion = 2;
enum uint gameCaptureMaxWidth = 16_384;
enum uint gameCaptureMaxHeight = 16_384;
enum uint gameCaptureSharedMagic = 0x41555348; // "AUSH"
enum uint gameCaptureSharedSlotCount = 3;
enum uint gameCaptureSharedSlotStride = 3_840 * 2_160 * 4;

enum GameCaptureSharedSlotState : int
{
    free = 0,
    filling = 1,
    ready = 2,
    reading = 3,
}

struct GameCaptureSharedHeader
{
    uint magic;
    uint protocolVersion;
    uint headerSize;
    uint slotCount;
    uint slotStride;
    shared int[gameCaptureSharedSlotCount] slotStates;
}

enum size_t gameCaptureSharedHeaderSize = GameCaptureSharedHeader.sizeof;
enum size_t gameCaptureSharedMappingSize = gameCaptureSharedHeaderSize +
    cast(size_t) gameCaptureSharedSlotCount * gameCaptureSharedSlotStride;

size_t gameCaptureSharedSlotOffset(uint slot)
{
    return gameCaptureSharedHeaderSize +
        cast(size_t) slot * gameCaptureSharedSlotStride;
}

enum GameCaptureMessage : uint
{
    ready = 1,
    frame = 2,
    error = 3,
}

enum GameCapturePixelFormat : uint
{
    none = 0,
    bgra8 = 1,
}

enum GameCaptureError : uint
{
    none = 0,
    hookSetupFailed = 1,
    unsupportedSwapChainFormat = 2,
    stagingTextureFailed = 3,
    pipeWriteFailed = 4,
    sharedMemoryCapacityExceeded = 5,
}

struct GameCapturePacketHeader
{
    uint magic;
    uint protocolVersion;
    uint headerSize;
    uint messageType;
    uint width;
    uint height;
    uint byteCount;
    uint pixelFormat;
    ulong sequence;
    ulong captureQpc;
    ulong captureQpcFrequency;
    uint droppedFrames;
    uint errorCode;
    uint sourceFormat;
    uint sharedSlot;
}

alias GameCaptureFrameHeader = GameCapturePacketHeader;
enum size_t gameCaptureHeaderSize = GameCapturePacketHeader.sizeof;

bool validGameCaptureHeader(const ref GameCapturePacketHeader header)
{
    if (header.magic != gameCaptureMagic ||
        header.protocolVersion != gameCaptureProtocolVersion ||
        header.headerSize != gameCaptureHeaderSize)
        return false;

    if (header.messageType == GameCaptureMessage.ready)
        return header.byteCount == 0 && header.errorCode == 0 &&
            header.pixelFormat == GameCapturePixelFormat.none;
    if (header.messageType == GameCaptureMessage.error)
        return header.byteCount == 0 && header.errorCode != 0 &&
            header.pixelFormat == GameCapturePixelFormat.none;
    if (header.messageType != GameCaptureMessage.frame ||
        header.pixelFormat != GameCapturePixelFormat.bgra8 ||
        header.errorCode != 0 || header.width == 0 || header.height == 0 ||
        header.width > gameCaptureMaxWidth ||
        header.height > gameCaptureMaxHeight || header.sequence == 0 ||
        header.captureQpc == 0 ||
        header.sharedSlot >= gameCaptureSharedSlotCount)
        return false;

    const expected = cast(ulong) header.width * header.height * 4;
    return expected <= gameCaptureSharedSlotStride &&
        header.byteCount == cast(uint) expected &&
        header.captureQpcFrequency > 0;
}

bool validGameCaptureSharedHeader(const ref GameCaptureSharedHeader header)
{
    return header.magic == gameCaptureSharedMagic &&
        header.protocolVersion == gameCaptureProtocolVersion &&
        header.headerSize == gameCaptureSharedHeaderSize &&
        header.slotCount == gameCaptureSharedSlotCount &&
        header.slotStride == gameCaptureSharedSlotStride;
}

string gameCaptureErrorMessage(uint errorCode, uint sourceFormat = 0)
{
    import std.conv : to;
    switch (cast(GameCaptureError) errorCode)
    {
        case GameCaptureError.none:
            return "";
        case GameCaptureError.hookSetupFailed:
            return "The D3D11 game-capture hook could not initialize.";
        case GameCaptureError.unsupportedSwapChainFormat:
            return "The game uses unsupported DXGI swap-chain format " ~
                sourceFormat.to!string ~
                ". SDR BGRA8, RGBA8, and RGB10A2 are supported; HDR16 capture is not yet supported.";
        case GameCaptureError.stagingTextureFailed:
            return "The game-capture hook could not create its asynchronous D3D11 staging textures.";
        case GameCaptureError.pipeWriteFailed:
            return "The game-capture frame pipe closed unexpectedly.";
        case GameCaptureError.sharedMemoryCapacityExceeded:
            return "The game back buffer is larger than the supported 3840x2160 shared-memory capture capacity.";
        default:
            return "The game-capture hook reported unknown error code " ~
                errorCode.to!string ~ ".";
    }
}

unittest
{
    static assert(GameCapturePacketHeader.sizeof == 72);

    GameCapturePacketHeader header;
    header.magic = gameCaptureMagic;
    header.protocolVersion = gameCaptureProtocolVersion;
    header.headerSize = gameCaptureHeaderSize;
    header.messageType = GameCaptureMessage.frame;
    header.width = 640;
    header.height = 480;
    header.byteCount = 640 * 480 * 4;
    header.pixelFormat = GameCapturePixelFormat.bgra8;
    header.sharedSlot = 1;
    header.sequence = 1;
    header.captureQpc = 1;
    header.captureQpcFrequency = 10_000_000;
    assert(validGameCaptureHeader(header));

    header.byteCount--;
    assert(!validGameCaptureHeader(header));
    header.byteCount = 640 * 480 * 4;
    header.protocolVersion++;
    assert(!validGameCaptureHeader(header));

    header = GameCapturePacketHeader.init;
    header.magic = gameCaptureMagic;
    header.protocolVersion = gameCaptureProtocolVersion;
    header.headerSize = gameCaptureHeaderSize;
    header.messageType = GameCaptureMessage.ready;
    assert(validGameCaptureHeader(header));

    GameCaptureSharedHeader sharedHeader;
    sharedHeader.magic = gameCaptureSharedMagic;
    sharedHeader.protocolVersion = gameCaptureProtocolVersion;
    sharedHeader.headerSize = gameCaptureSharedHeaderSize;
    sharedHeader.slotCount = gameCaptureSharedSlotCount;
    sharedHeader.slotStride = gameCaptureSharedSlotStride;
    assert(validGameCaptureSharedHeader(sharedHeader));
    static assert(GameCaptureSharedHeader.sizeof == 32);
}
