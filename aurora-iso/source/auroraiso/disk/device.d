/**
 * Random-access byte device abstraction for the from-scratch partitioner.
 *
 * A device is a flat range of bytes addressed by absolute offset. It can be a
 * physical disk, a partition window inside a disk, an in-memory image (used by
 * the unit tests), or a regular file. Every higher layer (GPT, FAT32, exFAT)
 * is written against this interface so the whole layout can be exercised
 * without touching real hardware.
 */
module auroraiso.disk.device;

import std.stdio : File;

/// A flat, random-access byte device.
interface BlockDevice
{
    /// Total size in bytes.
    ulong size() const;

    /// Logical sector size in bytes (512 for classic media).
    uint sectorSize() const;

    /// Read exactly buffer.length bytes starting at offset.
    void read(ulong offset, ubyte[] buffer);

    /// Write all of data starting at offset.
    void write(ulong offset, const(ubyte)[] data);

    /// Flush any buffered writes to the backing store.
    void flush();
}

/// In-memory device: the unit tests build a whole disk image in RAM.
final class MemoryBlockDevice : BlockDevice
{
    private ubyte[] storage;
    private uint sector;

    this(ulong bytes, uint sectorSize = 512)
    {
        storage = new ubyte[cast(size_t) bytes];
        sector = sectorSize != 0 ? sectorSize : 512;
    }

    ulong size() const { return storage.length; }
    uint sectorSize() const { return sector; }

    void read(ulong offset, ubyte[] buffer)
    {
        if (offset + buffer.length > storage.length)
            throw new Exception("MemoryBlockDevice: read past end of device");
        buffer[] = storage[cast(size_t) offset .. cast(size_t) (offset + buffer.length)];
    }

    void write(ulong offset, const(ubyte)[] data)
    {
        if (offset + data.length > storage.length)
            throw new Exception("MemoryBlockDevice: write past end of device");
        storage[cast(size_t) offset .. cast(size_t) (offset + data.length)] = data[];
    }

    void flush() {}

    /// Direct view of the backing bytes (tests and file dumps only).
    ubyte[] raw() { return storage; }
}

/// A window into another device, so a partition can be treated as its own device.
final class SubDevice : BlockDevice
{
    private BlockDevice parent;
    private ulong base;
    private ulong lengthBytes;
    private uint sector;

    this(BlockDevice parent, ulong base, ulong lengthBytes, uint sectorSize = 0)
    {
        if (base + lengthBytes > parent.size())
            throw new Exception("SubDevice: window exceeds parent device");
        this.parent = parent;
        this.base = base;
        this.lengthBytes = lengthBytes;
        this.sector = sectorSize != 0 ? sectorSize : parent.sectorSize();
    }

    ulong size() const { return lengthBytes; }
    uint sectorSize() const { return sector; }
    ulong baseOffset() const { return base; }

    void read(ulong offset, ubyte[] buffer)
    {
        if (offset + buffer.length > lengthBytes)
            throw new Exception("SubDevice: read past end of window");
        parent.read(base + offset, buffer);
    }

    void write(ulong offset, const(ubyte)[] data)
    {
        if (offset + data.length > lengthBytes)
            throw new Exception("SubDevice: write past end of window");
        parent.write(base + offset, data);
    }

    void flush() { parent.flush(); }
}

/// A device backed by a regular file, so an image can be written then inspected.
final class FileBlockDevice : BlockDevice
{
    private File file;
    private ulong lengthBytes;
    private uint sector;

    this(string path, ulong bytes, uint sectorSize = 512)
    {
        file = File(path, "w+b");
        if (bytes > 0)
        {
            file.seek(cast(long) (bytes - 1));
            file.rawWrite([cast(ubyte) 0]);
        }
        file.flush();
        lengthBytes = bytes;
        sector = sectorSize != 0 ? sectorSize : 512;
    }

    ulong size() const { return lengthBytes; }
    uint sectorSize() const { return sector; }

    void read(ulong offset, ubyte[] buffer)
    {
        file.seek(cast(long) offset);
        auto got = file.rawRead(buffer);
        if (got.length != buffer.length)
            throw new Exception("FileBlockDevice: short read");
    }

    void write(ulong offset, const(ubyte)[] data)
    {
        file.seek(cast(long) offset);
        file.rawWrite(data);
    }

    void flush() { file.flush(); }

    /// Close the backing file so it can be moved or deleted.
    void close() { file.close(); }
}
