/**
 * USB device discovery and low-level device preparation for Linux installs.
 *
 * Everything is done through the Win32 API directly (kernel32 plus a runtime
 * load of fmifs.dll for formatting), so the executable remains self-contained.
 * Raw image writing needs administrator rights; the module reports that
 * cleanly instead of failing silently.
 */
module auroraiso.usb;

import auroraiso.iso;

import std.array : appender;
import std.conv : to;
import std.file : exists;
import std.format : format;
import std.path : baseName;
import std.stdio : File;
import std.string : strip;
import std.utf : toUTF16z;

/// A removable volume and the physical disk that hosts it.
struct UsbDevice
{
    char letter;            // "E" for E:\
    string drivePath;       // "E:\\"
    string devicePath;      // "\\\\.\\PhysicalDriveN"
    string volumeLabel;
    string fileSystem;
    string model;
    ulong totalBytes;
    ulong freeBytes;
    uint diskNumber;
    bool hasDiskNumber;
    bool removable;

    string displayName() const
    {
        string label = volumeLabel.length > 0 ? volumeLabel : "(no label)";
        return format("%c:  %s  [%s]  %s", letter, label,
            fileSystem.length > 0 ? fileSystem : "raw", sizeText());
    }

    string sizeText() const
    {
        return formatSize(totalBytes);
    }
}

/// Progress report for long device operations.
struct DeviceProgress
{
    double fraction;
    string message;
}

version (Windows)
{
    private extern(Windows)
    {
        alias void* HANDLE;
        alias int BOOL;
        alias uint DWORD;
        alias ushort WORD;
        alias ubyte BYTE;
        alias wchar WCHAR;
        alias const(WCHAR)* LPCWSTR;
        alias WCHAR* LPWSTR;
        alias void* LPVOID;
        alias const(void)* LPCVOID;
        alias ulong ULONGLONG;
        alias long LARGE_INTEGER;
        alias void* HMODULE;

        HANDLE CreateFileW(LPCWSTR fileName, DWORD desiredAccess,
            DWORD shareMode, void* security, DWORD creationDisposition,
            DWORD flagsAndAttributes, HANDLE templateFile);
        BOOL DeviceIoControl(HANDLE device, DWORD controlCode, LPVOID inBuffer,
            DWORD inSize, LPVOID outBuffer, DWORD outSize, DWORD* returned,
            void* overlapped);
        BOOL CloseHandle(HANDLE handle);
        BOOL FlushFileBuffers(HANDLE handle);
        BOOL WriteFile(HANDLE handle, LPCVOID buffer, DWORD toWrite,
            DWORD* written, void* overlapped);
        BOOL ReadFile(HANDLE handle, LPVOID buffer, DWORD toRead,
            DWORD* read, void* overlapped);
        BOOL SetFilePointerEx(HANDLE handle, LARGE_INTEGER distance,
            LARGE_INTEGER* newPosition, DWORD moveMethod);
        DWORD GetLogicalDrives();
        uint GetDriveTypeW(LPCWSTR rootPathName);
        BOOL GetVolumeInformationW(LPCWSTR rootPathName, LPWSTR volumeNameBuffer,
            DWORD volumeNameSize, DWORD* volumeSerialNumber,
            DWORD* maximumComponentLength, DWORD* fileSystemFlags,
            LPWSTR fileSystemNameBuffer, DWORD fileSystemNameSize);
        BOOL GetDiskFreeSpaceExW(LPCWSTR directoryName,
            ULONGLONG* freeBytesAvailable, ULONGLONG* totalNumberOfBytes,
            ULONGLONG* totalNumberOfFreeBytes);
        DWORD GetLastError();
        HMODULE LoadLibraryW(LPCWSTR moduleName);
        void* GetProcAddress(HMODULE library, const(char)* symbol);
        BOOL FreeLibrary(HMODULE library);
    }

    private enum uint genericRead = 0x80000000;
    private enum uint genericWrite = 0x40000000;
    private enum uint fileShareRead = 0x00000001;
    private enum uint fileShareWrite = 0x00000002;
    private enum uint openExisting = 3;
    private enum uint invalidHandle = 0xFFFFFFFF;
    private enum uint driveRemovable = 2;

    private enum uint fscLockVolume = 0x00090018;
    private enum uint fscUnlockVolume = 0x0009001C;
    private enum uint fscDismountVolume = 0x00090020;
    private enum uint ioctlVolumeGetDiskExtents = 0x00560000;
    private enum uint ioctlStorageQueryProperty = 0x002D1400;
    private enum uint storageDeviceProperty = 0;
    private enum uint propertyStandardQuery = 0;

    private struct DISK_EXTENT
    {
        DWORD diskNumber;
        LARGE_INTEGER startingOffset;
        LARGE_INTEGER extentLength;
    }

    private struct VOLUME_DISK_EXTENTS
    {
        DWORD numberOfDiskExtents;
        DWORD padding;
        DISK_EXTENT[16] extents;
    }

    private struct STORAGE_PROPERTY_QUERY
    {
        DWORD propertyId;
        DWORD queryType;
        BYTE[4] additionalParameters;
    }

    private struct STORAGE_DEVICE_DESCRIPTOR
    {
        DWORD descriptorVersion;
        DWORD size;
        BYTE deviceType;
        BYTE deviceTypeModifier;
        BYTE removableMedia;
        BYTE commandQueueing;
        DWORD vendorIdOffset;
        DWORD productIdOffset;
        DWORD productRevisionOffset;
        DWORD serialNumberOffset;
        int busType;
        DWORD rawPropertiesLength;
        BYTE rawDevicePropertiesPadded;
    }

    private alias FormatCallback = BOOL function(DWORD command, LPVOID modpack,
        LPVOID param);

    private alias FormatExProc = BOOL function(LPWSTR driveRoot, DWORD mediaFlag,
        LPWSTR formatName, LPWSTR label, BOOL quickFormat, DWORD clusterSize,
        FormatCallback callback);

    private enum uint fmifsHardDisk = 0x0C;

    private HANDLE openDevice(string path, uint access, uint share)
    {
        auto wide = path.toUTF16z;
        return CreateFileW(wide, access, share, null, openExisting, 0, null);
    }

    private bool handleValid(HANDLE handle)
    {
        return handle !is null && cast(uint) cast(size_t) handle != invalidHandle;
    }

    /// True when the process can write to raw physical drives.
    bool hasRawDiskAccess()
    {
        auto handle = openDevice("\\\\.\\PhysicalDrive0", genericRead,
            fileShareRead | fileShareWrite);
        if (!handleValid(handle))
            return false;
        CloseHandle(handle);
        return true;
    }

    /// List removable (USB) volumes with their backing physical disk number.
    UsbDevice[] enumerateUsbDevices()
    {
        UsbDevice[] devices;
        const mask = GetLogicalDrives();
        foreach (index; 0 .. 26)
        {
            if ((mask & (1u << index)) == 0)
                continue;
            const letter = cast(char)('A' + index);
            auto root = format("%c:\\", letter);
            if (GetDriveTypeW(root.toUTF16z) != driveRemovable)
                continue;

            UsbDevice device;
            device.letter = letter;
            device.drivePath = root;
            device.removable = true;
            device.volumeLabel = queryVolumeLabel(root);
            device.fileSystem = queryFileSystem(root);
            queryFreeSpace(root, device.totalBytes, device.freeBytes);
            if (queryDiskNumber(letter, device.diskNumber))
            {
                device.hasDiskNumber = true;
                device.devicePath = "\\\\.\\PhysicalDrive" ~ device.diskNumber.to!string;
                device.model = queryDiskModel(device.diskNumber);
            }
            devices ~= device;
        }
        return devices;
    }

    private string queryVolumeLabel(string root)
    {
        WCHAR[261] buffer;
        if (!GetVolumeInformationW(root.toUTF16z, buffer.ptr, 261, null, null,
            null, null, 0))
            return "";
        return fromWide(buffer[]);
    }

    private string queryFileSystem(string root)
    {
        WCHAR[261] buffer;
        if (!GetVolumeInformationW(root.toUTF16z, null, 0, null, null, null,
            buffer.ptr, 261))
            return "";
        return fromWide(buffer[]);
    }

    private void queryFreeSpace(string root, out ulong total, out ulong free)
    {
        ULONGLONG available;
        ULONGLONG totalBytes;
        ULONGLONG freeBytes;
        total = 0;
        free = 0;
        if (GetDiskFreeSpaceExW(root.toUTF16z, &available, &totalBytes, &freeBytes))
        {
            total = totalBytes;
            free = freeBytes;
        }
    }

    private bool queryDiskNumber(char letter, out uint diskNumber)
    {
        diskNumber = 0;
        auto path = format("\\\\.\\%c:", letter);
        auto handle = openDevice(path, genericRead, fileShareRead | fileShareWrite);
        if (!handleValid(handle))
            return false;
        scope(exit) CloseHandle(handle);

        VOLUME_DISK_EXTENTS extents;
        DWORD returned;
        if (!DeviceIoControl(handle, ioctlVolumeGetDiskExtents, null, 0,
            &extents, VOLUME_DISK_EXTENTS.sizeof, &returned, null))
            return false;
        if (extents.numberOfDiskExtents == 0)
            return false;
        diskNumber = extents.extents[0].diskNumber;
        return true;
    }

    private string queryDiskModel(uint diskNumber)
    {
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        auto handle = openDevice(path, genericRead, fileShareRead | fileShareWrite);
        if (!handleValid(handle))
            return "";
        scope(exit) CloseHandle(handle);

        STORAGE_PROPERTY_QUERY query;
        query.propertyId = storageDeviceProperty;
        query.queryType = propertyStandardQuery;
        auto buffer = new ubyte[1024];
        DWORD returned;
        if (!DeviceIoControl(handle, ioctlStorageQueryProperty, &query,
            STORAGE_PROPERTY_QUERY.sizeof, buffer.ptr, cast(DWORD) buffer.length,
            &returned, null))
            return "";

        if (returned < STORAGE_DEVICE_DESCRIPTOR.sizeof)
            return "";
        auto descriptor = cast(STORAGE_DEVICE_DESCRIPTOR*) buffer.ptr;
        string vendor;
        string product;
        if (descriptor.vendorIdOffset != 0 &&
            descriptor.vendorIdOffset < buffer.length)
            vendor = cString(buffer, descriptor.vendorIdOffset);
        if (descriptor.productIdOffset != 0 &&
            descriptor.productIdOffset < buffer.length)
            product = cString(buffer, descriptor.productIdOffset);
        auto text = (vendor ~ " " ~ product).strip;
        return text;
    }

    private static string cString(const(ubyte)[] buffer, size_t offset)
    {
        auto builder = appender!(char[])();
        size_t index = offset;
        while (index < buffer.length && buffer[index] != 0)
        {
            builder.put(cast(char) buffer[index]);
            ++index;
        }
        return builder.data.idup.strip;
    }

    /// Lock and dismount every mounted volume on a physical disk.
    private void dismountVolumes(uint diskNumber)
    {
        const mask = GetLogicalDrives();
        foreach (index; 0 .. 26)
        {
            if ((mask & (1u << index)) == 0)
                continue;
            const letter = cast(char)('A' + index);
            uint found;
            if (!queryDiskNumber(letter, found) || found != diskNumber)
                continue;
            auto path = format("\\\\.\\%c:", letter);
            auto handle = openDevice(path, genericRead | genericWrite,
                fileShareRead | fileShareWrite);
            if (!handleValid(handle))
                continue;
            DWORD returned;
            DeviceIoControl(handle, fscLockVolume, null, 0, null, 0, &returned, null);
            DeviceIoControl(handle, fscDismountVolume, null, 0, null, 0, &returned, null);
            CloseHandle(handle);
        }
    }

    /**
     * Write a raw image (bootable hybrid ISO) directly to a physical disk.
     * This is the same byte-for-byte "dd" operation used to build Linux USB
     * installers and works for every modern hybrid distribution. Requires
     * administrator rights.
     */
    ulong writeImageToPhysicalDrive(string imagePath, uint diskNumber,
        scope void delegate(DeviceProgress) onProgress = null,
        scope bool delegate() cancel = null)
    {
        if (!exists(imagePath))
            throw new Exception("Image not found: " ~ imagePath);

        dismountVolumes(diskNumber);

        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite);
        if (!handleValid(handle))
            throw new Exception("Cannot open " ~ path ~
                " (run Aurora ISO as administrator)");

        scope(exit) CloseHandle(handle);

        auto source = File(imagePath, "rb");
        auto buffer = new ubyte[1 << 20];
        const totalSize = source.size();
        ulong written = 0;
        while (true)
        {
            if (cancel !is null && cancel())
                throw new Exception("cancelled");
            auto got = source.rawRead(buffer);
            if (got.length == 0)
                break;
            DWORD chunkWritten;
            if (!WriteFile(handle, got.ptr, cast(DWORD) got.length, &chunkWritten, null))
                throw new Exception("Write failed at offset " ~ written.to!string ~
                    " (error " ~ GetLastError().to!string ~ ")");
            written += chunkWritten;
            if (onProgress !is null)
                onProgress(DeviceProgress(totalSize == 0 ? 0.0 :
                    cast(double) written / cast(double) totalSize,
                    format("Writing %s / %s", formatSize(written),
                        formatSize(totalSize))));
        }
        FlushFileBuffers(handle);
        return written;
    }

    /// Format a mounted volume using fmifs. Requires administrator rights.
    bool formatVolume(char letter, string fileSystem = "FAT32",
        string label = "AURORA-USB", bool quick = true)
    {
        auto library = LoadLibraryW("fmifs.dll".toUTF16z);
        if (library is null)
            throw new Exception("Cannot load fmifs.dll");
        scope(exit) FreeLibrary(library);

        auto proc = GetProcAddress(library, "FormatEx");
        if (proc is null)
            throw new Exception("FormatEx is unavailable");

        auto root = format("%c:\\", letter);
        auto rootZ = root.toUTF16z;
        auto fsZ = fileSystem.toUTF16z;
        auto labelZ = label.toUTF16z;

        auto formatProc = cast(FormatExProc) proc;
        const result = formatProc(cast(LPWSTR) rootZ, fmifsHardDisk,
            cast(LPWSTR) fsZ, cast(LPWSTR) labelZ, quick ? 1 : 0, 0,
            &formatCallback);
        return result != 0;
    }

    private static BOOL formatCallback(DWORD command, LPVOID modpack, LPVOID param)
    {
        return 1;
    }

    /// Erase a whole physical disk's first sectors so stale data cannot confuse boot.
    void wipeDeviceStart(uint diskNumber, ulong bytes = 16 * 1024 * 1024)
    {
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite);
        if (!handleValid(handle))
            throw new Exception("Cannot open " ~ path ~
                " (run Aurora ISO as administrator)");
        scope(exit) CloseHandle(handle);
        dismountVolumes(diskNumber);
        auto zeros = new ubyte[1 << 20];
        ulong written = 0;
        while (written < bytes)
        {
            auto chunk = cast(DWORD) (bytes - written < zeros.length ?
                bytes - written : zeros.length);
            DWORD done;
            if (!WriteFile(handle, zeros.ptr, chunk, &done, null))
                break;
            if (done == 0)
                break;
            written += done;
        }
        FlushFileBuffers(handle);
    }
}
else
{
    struct DeviceProgressDisabled {}
}

/// Small helper so callers can build a human-readable size without importing
/// formatting details.
string formatSize(ulong bytes)
{
    if (bytes < 1024)
        return bytes.to!string ~ " B";
    static immutable string[] units = ["KiB", "MiB", "GiB", "TiB"];
    double value = cast(double) bytes;
    size_t unit = 0;
    value /= 1024.0;
    while (value >= 1024.0 && unit + 1 < units.length)
    {
        value /= 1024.0;
        ++unit;
    }
    return format("%.1f %s", value, units[unit]);
}

version (Windows)
{
    private string fromWide(const(WCHAR)[] buffer)
    {
        import std.utf : toUTF8;
        dchar[] chars;
        size_t index = 0;
        while (index < buffer.length && buffer[index] != 0)
        {
            chars ~= cast(dchar) buffer[index];
            ++index;
        }
        return toUTF8(chars).strip;
    }
}
else
{
    private string fromWide(const(wchar)[] buffer)
    {
        return "";
    }
}

version (Windows)
{
    /// Enumerate removable USB volumes (empty list on other platforms).
    UsbDevice[] usbDevices()
    {
        return enumerateUsbDevices();
    }
}
else
{
    UsbDevice[] usbDevices()
    {
        return [];
    }

    bool hasRawDiskAccess() { return false; }
}

unittest
{
    assert(formatSize(512) == "512 B");
    assert(formatSize(2048) == "2.0 KiB");
    assert(formatSize(1024 * 1024) == "1.0 MiB");
}
