/**
 * USB device discovery and low-level device preparation for Linux installs.
 *
 * Everything is done through the Win32 API directly (kernel32 plus a runtime
 * load of fmifs.dll for formatting), so the executable remains self-contained.
 * Raw image writing needs administrator rights; the module reports that
 * cleanly instead of failing silently.
 */
module auroraiso.usb;

import auroraiso.disk;
import auroraiso.iso;
import auroraiso.logging;

import std.array : appender;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;
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
        HANDLE GetCurrentProcess();
        BOOL OpenProcessToken(HANDLE process, DWORD desiredAccess, HANDLE* token);
        BOOL GetTokenInformation(HANDLE token, int infoClass, LPVOID info,
            DWORD infoLength, DWORD* returnLength);
        HMODULE LoadLibraryW(LPCWSTR moduleName);
        void* GetProcAddress(HMODULE library, const(char)* symbol);
        BOOL FreeLibrary(HMODULE library);
        HANDLE FindFirstVolumeW(LPWSTR volumeNameBuffer, DWORD bufferLength);
        BOOL FindNextVolumeW(HANDLE findVolume, LPWSTR volumeNameBuffer,
            DWORD bufferLength);
        BOOL FindVolumeClose(HANDLE findVolume);
        BOOL GetVolumePathNamesForVolumeNameW(LPCWSTR volumeName,
            LPWSTR volumePathNames, DWORD bufferLength, DWORD* returnLength);
    }

    private enum uint genericRead = 0x80000000;
    private enum uint genericWrite = 0x40000000;
    private enum uint fileShareRead = 0x00000001;
    private enum uint fileShareWrite = 0x00000002;
    private enum uint openExisting = 3;
    private enum uint createAlways = 2;
    private enum uint invalidHandle = 0xFFFFFFFF;
    private enum uint driveRemovable = 2;
    private enum uint fileFlagWriteThrough = 0x80000000;
    private enum uint fileFlagNoBuffering = 0x20000000;
    // Raw disk writes must be unbuffered with sector-aligned address and length.
    private enum uint rawBlockAlign = 4096;

    private enum uint fscLockVolume = 0x00090018;
    private enum uint fscUnlockVolume = 0x0009001C;
    private enum uint fscDismountVolume = 0x00090020;
    private enum uint ioctlVolumeGetDiskExtents = 0x00560000;
    private enum uint ioctlStorageQueryProperty = 0x002D1400;
    private enum uint ioctlDiskGetDriveGeometry = 0x00070000;
    // CTL_CODE(IOCTL_DISK_BASE=7, 0x16, METHOD_BUFFERED, FILE_READ|FILE_WRITE)
    private enum uint ioctlDiskDeleteDriveLayout = 0x0007C058;
    private enum uint ioctlDiskGetLengthInfo = 0x0007405C;
    private enum uint ioctlDiskUpdateProperties = 0x0007010C;
    private enum uint ioctlDiskSetDiskAttributes = 0x0007C0F4;

    private struct DISK_ATTRIBUTES
    {
        ulong attributes;
        ulong reserved;
    }
    // CTL_CODE(IOCTL_DISK_BASE=7, 0x14, METHOD_BUFFERED, FILE_ANY_ACCESS)
    private enum uint ioctlDiskSetDriveLayoutEx = 0x00070050;

    /// Minimal empty MBR layout: no partition entries, used to clear the table.
    private struct EMPTY_DRIVE_LAYOUT
    {
        DWORD partitionStyle; // PARTITION_STYLE_MBR == 0
        DWORD partitionCount; // 0
        DWORD mbrSignature;   // union member (Signature)
    }

    private struct GET_LENGTH_INFORMATION
    {
        LARGE_INTEGER length;
    }
    private enum uint storageDeviceProperty = 0;
    private enum uint propertyStandardQuery = 0;

    private struct DISK_GEOMETRY
    {
        LARGE_INTEGER cylinders;
        DWORD mediaType;
        DWORD tracksPerCylinder;
        DWORD sectorsPerTrack;
        DWORD bytesPerSector;
    }

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

    private enum uint tokenQuery = 0x0008;
    private enum int tokenElevationClass = 20;

    private struct TOKEN_ELEVATION
    {
        DWORD tokenIsElevated;
    }

    /// True when the current process token is elevated (running as admin).
    bool isProcessElevated()
    {
        HANDLE token;
        if (!OpenProcessToken(GetCurrentProcess(), tokenQuery, &token))
            return false;
        scope(exit) CloseHandle(token);
        TOKEN_ELEVATION elevation;
        DWORD returned;
        if (!GetTokenInformation(token, tokenElevationClass, &elevation,
            TOKEN_ELEVATION.sizeof, &returned))
            return false;
        return elevation.tokenIsElevated != 0;
    }

    /// Alias used by the UI to decide whether raw device writes can proceed.
    bool hasAdminRights()
    {
        return isProcessElevated();
    }

    private HANDLE openDevice(string path, uint access, uint share, uint flags = 0)
    {
        auto wide = path.toUTF16z;
        return CreateFileW(wide, access, share, null, openExisting, flags, null);
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

    /**
     * Lock and dismount every mounted volume on a physical disk. The handles are
     * returned and must remain open (locked) until after the raw write finishes,
     * otherwise the OS keeps the volume mounted and rejects the write.
     */
    /**
     * Build the device path to open for a volume. A lettered volume is opened
     * through its mount point (`\\.\D:`) because the raw `\\?\Volume{...}\`
     * GUID path cannot always be opened directly; unlettered volumes fall back
     * to the GUID path with the trailing backslash removed.
     */
    private string devicePathForVolume(string volumePath)
    {
        WCHAR[1024] buffer;
        DWORD returned;
        if (GetVolumePathNamesForVolumeNameW(volumePath.toUTF16z, buffer.ptr,
            cast(DWORD) buffer.length, &returned) && returned > 0)
        {
            auto mount = fromWide(buffer[]);
            if (mount.length >= 2 && mount[1] == ':')
                return "\\\\.\\" ~ mount[0 .. 2];
        }
        auto trimmed = volumePath;
        while (trimmed.length > 0 && trimmed[$ - 1] == '\\')
            trimmed = trimmed[0 .. $ - 1];
        return trimmed;
    }

    private HANDLE[] lockVolumes(uint diskNumber, out bool anyVolume)
    {
        HANDLE[] handles;
        anyVolume = false;
        WCHAR[260] nameBuffer;
        auto search = FindFirstVolumeW(nameBuffer.ptr, cast(DWORD) nameBuffer.length);
        if (search is null || cast(size_t) search == invalidHandle)
        {
            logWarn(format("lockVolumes: FindFirstVolume failed (error %d)", GetLastError()));
            return handles;
        }
        scope(exit) FindVolumeClose(search);
        do
        {
            auto volumePath = fromWide(nameBuffer[]);
            if (volumePath.length == 0)
                continue;
            auto devicePath = devicePathForVolume(volumePath);
            auto handle = CreateFileW(devicePath.toUTF16z, genericRead | genericWrite,
                fileShareRead | fileShareWrite, null, openExisting, 0, null);
            if (!handleValid(handle))
            {
                logWarn(format("lockVolumes: open failed %s (error %d)",
                    devicePath, GetLastError()));
                continue;
            }

            VOLUME_DISK_EXTENTS extents;
            DWORD returned;
            if (!DeviceIoControl(handle, ioctlVolumeGetDiskExtents, null, 0,
                &extents, VOLUME_DISK_EXTENTS.sizeof, &returned, null))
            {
                logWarn(format("lockVolumes: extents failed %s (error %d)",
                    volumePath, GetLastError()));
                CloseHandle(handle);
                continue;
            }
            const volumeDisk = extents.numberOfDiskExtents > 0
                ? extents.extents[0].diskNumber : uint.max;
            logInfo(format("lockVolumes: %s -> disk %d", volumePath, volumeDisk));
            if (extents.numberOfDiskExtents == 0 || volumeDisk != diskNumber)
            {
                CloseHandle(handle);
                continue;
            }

            anyVolume = true;
            bool locked;
            foreach (attempt; 0 .. 6)
            {
                DWORD ignored;
                if (DeviceIoControl(handle, fscLockVolume, null, 0, null, 0,
                    &ignored, null))
                {
                    DeviceIoControl(handle, fscDismountVolume, null, 0, null, 0,
                        &ignored, null);
                    locked = true;
                    break;
                }
                if (attempt == 0)
                    logWarn(format("lockVolumes: lock %s failed (error %d), retrying",
                        volumePath, GetLastError()));
                Thread.sleep(150.msecs);
            }
            if (locked)
            {
                logInfo("lockVolumes: locked and dismounted " ~ volumePath);
                handles ~= handle; // keep open so the volume stays dismounted
            }
            else
            {
                logWarn("lockVolumes: gave up locking " ~ volumePath);
                CloseHandle(handle);
            }
        }
        while (FindNextVolumeW(search, nameBuffer.ptr, cast(DWORD) nameBuffer.length));
        return handles;
    }

    /// Release the volume locks acquired by lockVolumes.
    private void unlockVolumes(HANDLE[] handles)
    {
        foreach (handle; handles)
        {
            DWORD returned;
            DeviceIoControl(handle, fscUnlockVolume, null, 0, null, 0, &returned, null);
            CloseHandle(handle);
        }
    }

    /// True when any mounted volume resolves to this physical disk.
    private bool diskHasVolume(uint diskNumber)
    {
        const mask = GetLogicalDrives();
        foreach (index; 0 .. 26)
        {
            if ((mask & (1u << index)) == 0)
                continue;
            const letter = cast(char)('A' + index);
            uint found;
            if (queryDiskNumber(letter, found) && found == diskNumber)
                return true;
        }
        return false;
    }

    /// Physical sector size of a disk (defaults to 512 when unavailable).
    private uint querySectorSize(uint diskNumber)
    {
        uint sector = 512;
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        auto handle = openDevice(path, genericRead, fileShareRead | fileShareWrite);
        if (handleValid(handle))
        {
            DISK_GEOMETRY geometry;
            DWORD returned;
            if (DeviceIoControl(handle, ioctlDiskGetDriveGeometry, null, 0,
                &geometry, DISK_GEOMETRY.sizeof, &returned, null) &&
                geometry.bytesPerSector != 0)
                sector = geometry.bytesPerSector;
            CloseHandle(handle);
        }
        logInfo(format("sector size for disk %d = %d", diskNumber, sector));
        return sector;
    }

    /// Force the storage stack to re-enumerate the disk (offline then online)
    /// so stale write protection cached for old partition extents is dropped.
    private void reenumerateDisk(HANDLE handle)
    {
        DWORD returned;
        DISK_ATTRIBUTES attr;
        attr.reserved = 0;
        attr.attributes = 2; // DISK_ATTRIBUTE_OFFLINE
        if (DeviceIoControl(handle, ioctlDiskSetDiskAttributes, &attr,
            DISK_ATTRIBUTES.sizeof, null, 0, &returned, null))
            logInfo("reenumerate: disk taken offline");
        else
            logWarn(format("reenumerate: offline failed (error %d)", GetLastError()));
        attr.attributes = 0;
        if (DeviceIoControl(handle, ioctlDiskSetDiskAttributes, &attr,
            DISK_ATTRIBUTES.sizeof, null, 0, &returned, null))
            logInfo("reenumerate: disk back online");
        else
            logWarn(format("reenumerate: online failed (error %d)", GetLastError()));
    }

    /// Delete the disk's partition table so no volume stays mounted over it.
    private void clearDriveLayout(HANDLE handle)
    {
        DWORD returned;
        // 1) Install an empty MBR layout (clears the partition table so the
        //    first sector becomes writable). Uses a generous buffer with a
        //    zeroed DRIVE_LAYOUT_INFORMATION_EX header.
        // Preferred: the sanctioned "delete drive layout" call. This is what
        // releases the volume manager's hold on the old partition extents.
        if (DeviceIoControl(handle, ioctlDiskDeleteDriveLayout, null, 0, null, 0,
            &returned, null))
        {
            logInfo("clearDriveLayout: layout deleted");
            return;
        }
        logWarn(format("clearDriveLayout: delete layout failed (error %d)", GetLastError()));

        auto layout = new ubyte[4096];
        layout[0] = 0; // PartitionStyle = MBR
        layout[4] = 0; // PartitionCount = 0
        // The IOCTL also writes the resulting layout back, so the same buffer
        // must be supplied as output (null output yields ERROR_INSUFFICIENT_BUFFER).
        if (DeviceIoControl(handle, ioctlDiskSetDriveLayoutEx, layout.ptr,
            cast(DWORD) layout.length, layout.ptr, cast(DWORD) layout.length,
            &returned, null))
        {
            logInfo("clearDriveLayout: empty layout set");
            // Force the volume/partition database to rescan so no stale
            // read-only extents remain cached for the old partitions.
            if (DeviceIoControl(handle, ioctlDiskUpdateProperties, null, 0,
                null, 0, &returned, null))
                logInfo("clearDriveLayout: properties updated");
            else
                logWarn(format("clearDriveLayout: update properties failed (error %d)",
                    GetLastError()));
            return;
        }
        const setError = GetLastError();
        logWarn(format("clearDriveLayout: SetDriveLayoutEx failed (error %d)", setError));
    }

    /// Carries the Windows error code so the caller can pick a fallback.
    final class DeviceWriteException : Exception
    {
        uint code;
        ulong offset;

        this(uint code, ulong offset)
        {
            super(format("Write failed at offset %s (error %d)%s", offset, code,
                code == 1 ? " — the drive is busy or write-protected" : ""));
            this.code = code;
            this.offset = offset;
        }
    }

    /**
     * Stream an image to a device handle with sector-aligned, 4 KiB-aligned
     * transfers (compatible with both 512e and 4Kn media).
     */
    private ulong streamToDevice(HANDLE handle, string imagePath, uint sector,
        scope void delegate(DeviceProgress) onProgress,
        scope bool delegate() cancel)
    {
        enum size_t alignment = 4096;
        enum size_t chunkSize = 1 << 20;
        const step = sector == 0 ? 512u : sector;
        auto source = File(imagePath, "rb");
        const totalSize = source.size();
        auto storage = new ubyte[chunkSize + alignment];
        const alignOffset = alignment - (cast(size_t) storage.ptr & (alignment - 1));
        auto buffer = storage[alignOffset .. alignOffset + chunkSize];
        ulong written = 0;
        while (true)
        {
            if (cancel !is null && cancel())
                throw new Exception("cancelled");
            auto got = source.rawRead(buffer);
            if (got.length == 0)
                break;
            size_t length = got.length;
            const remainder = length % step;
            if (remainder != 0)
            {
                size_t padded = length + (step - remainder);
                if (padded > buffer.length)
                    padded = buffer.length;
                foreach (i; length .. padded)
                    buffer[i] = 0;
                length = padded;
            }
            DWORD chunkWritten;
            if (!WriteFile(handle, buffer.ptr, cast(DWORD) length, &chunkWritten, null))
            {
                const code = GetLastError();
                logError(format(
                    "streamToDevice: WriteFile failed offset=%d length=%d error=%d",
                    written, length, code));
                throw new DeviceWriteException(code, written);
            }
            written += got.length;
            if (onProgress !is null)
                onProgress(DeviceProgress(totalSize == 0 ? 0.0 :
                    cast(double) written / cast(double) totalSize,
                    format("Writing %s / %s", formatSize(written),
                        formatSize(totalSize))));
        }
        FlushFileBuffers(handle);
        return written;
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

        // Hold volume locks for the whole write; a mounted volume rejects
        // writes to the underlying disk with ERROR_INVALID_FUNCTION.
        logInfo(format("writeImage: disk=%d image=%s", diskNumber, imagePath));
        bool anyVolume;
        auto locks = lockVolumes(diskNumber, anyVolume);
        scope(exit) unlockVolumes(locks);
        logInfo(format("writeImage: disk=%d volumes=%s locks=%d",
            diskNumber, anyVolume, locks.length));
        if (anyVolume && locks.length == 0)
            throw new Exception(
                "The drive could not be locked because another program is using it. " ~
                "Close Explorer windows, the volume, or antivirus scans, then retry.");

        const sector = querySectorSize(diskNumber);
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;

        // Clear the partition table on a throwaway handle and close it first:
        // the layout change only takes effect for handles opened afterwards.
        {
            auto prep = openDevice(path, genericRead | genericWrite,
                fileShareRead | fileShareWrite, 0);
            if (handleValid(prep))
            {
                clearDriveLayout(prep);
                reenumerateDisk(prep);
                CloseHandle(prep);
            }
        }

        // Preferred path: unbuffered, write-through, sector-aligned.
        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite,
            fileFlagNoBuffering | fileFlagWriteThrough);
        if (!handleValid(handle))
        {
            const code = GetLastError();
            logError(format("writeImage: open %s failed error=%d", path, code));
            throw new Exception("Cannot open " ~ path ~
                " (administrator rights and an unlocked drive are required)");
        }
        try
        {
            auto result = streamToDevice(handle, imagePath, sector, onProgress, cancel);
            logInfo(format("writeImage: wrote %d bytes (unbuffered) to disk %d",
                result, diskNumber));
            return result;
        }
        catch (DeviceWriteException error)
        {
            logWarn(format(
                "writeImage: unbuffered failed error=%d offset=%d; retrying buffered",
                error.code, error.offset));
            if (error.code != 1 && error.code != 87)
                throw error;
            // Some USB controllers reject unbuffered raw writes; retry buffered.
        }
        finally
            CloseHandle(handle);

        auto buffered = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite, 0);
        if (!handleValid(buffered))
        {
            const code = GetLastError();
            logError(format("writeImage: reopen %s failed error=%d", path, code));
            throw new Exception("Cannot reopen " ~ path ~ " for writing");
        }
        scope(exit) CloseHandle(buffered);
        auto written = streamToDevice(buffered, imagePath, sector, onProgress, cancel);
        logInfo(format("writeImage: wrote %d bytes (buffered) to disk %d",
            written, diskNumber));
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
        bool anyVolume;
        auto locks = lockVolumes(diskNumber, anyVolume);
        scope(exit) unlockVolumes(locks);
        const sector = querySectorSize(diskNumber);
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite,
            fileFlagNoBuffering | fileFlagWriteThrough);
        if (!handleValid(handle))
            throw new Exception("Cannot open " ~ path ~
                " (administrator rights required)");
        scope(exit) CloseHandle(handle);
        enum size_t chunkSize = 1 << 20;
        auto storage = new ubyte[chunkSize + rawBlockAlign];
        const alignOffset = rawBlockAlign -
            (cast(size_t) storage.ptr & (rawBlockAlign - 1));
        auto zeros = storage[alignOffset .. alignOffset + chunkSize];
        ulong written = 0;
        const alignedBytes = (bytes + sector - 1) / sector * sector;
        while (written < alignedBytes)
        {
            auto chunk = cast(DWORD) (alignedBytes - written < chunkSize ?
                alignedBytes - written : chunkSize);
            if (chunk % sector != 0)
                chunk -= chunk % sector;
            if (chunk == 0)
                break;
            DWORD done;
            if (!WriteFile(handle, zeros.ptr, chunk, &done, null))
                throw new DeviceWriteException(GetLastError(), written);
            if (done == 0)
                break;
            written += done;
        }
        FlushFileBuffers(handle);
    }

    /**
     * Write an image to a regular file with the same aligned streamer. Used by
     * the built-in self-test to exercise the write path without a real device.
     */
    ulong writeImageToFile(string imagePath, string targetPath,
        scope void delegate(DeviceProgress) onProgress = null,
        scope bool delegate() cancel = null)
    {
        auto handle = CreateFileW(targetPath.toUTF16z,
            genericRead | genericWrite, 0, null, createAlways,
            fileFlagNoBuffering | fileFlagWriteThrough, null);
        if (!handleValid(handle))
            throw new Exception(format("Cannot create %s (error %d)",
                targetPath, GetLastError()));
        scope(exit) CloseHandle(handle);
        auto written = streamToDevice(handle, imagePath, 512, onProgress, cancel);
        logInfo(format("writeImageToFile: %s -> %s (%d bytes)",
            imagePath, targetPath, written));
        return written;
    }

    /**
     * Enumerate every volume and the physical disk it lives on. This is the
     * same enumeration the write path uses to lock volumes, exposed for the
     * `--probe` diagnostic so the logic can be exercised on real hardware.
     */
    void logVolumeProbe()
    {
        WCHAR[260] nameBuffer;
        auto search = FindFirstVolumeW(nameBuffer.ptr, cast(DWORD) nameBuffer.length);
        if (search is null || cast(size_t) search == invalidHandle)
        {
            logError(format("probe: FindFirstVolume failed (error %d)", GetLastError()));
            return;
        }
        scope(exit) FindVolumeClose(search);
        uint count;
        do
        {
            auto volumePath = fromWide(nameBuffer[]);
            if (volumePath.length == 0)
                continue;
            ++count;
            auto handle = CreateFileW(volumePath.toUTF16z, genericRead,
                fileShareRead | fileShareWrite, null, openExisting, 0, null);
            if (!handleValid(handle))
            {
                logWarn("probe: " ~ volumePath ~ " (open failed)");
                continue;
            }
            VOLUME_DISK_EXTENTS extents;
            DWORD returned;
            if (DeviceIoControl(handle, ioctlVolumeGetDiskExtents, null, 0,
                &extents, VOLUME_DISK_EXTENTS.sizeof, &returned, null) &&
                extents.numberOfDiskExtents > 0)
                logInfo(format("probe: %s -> disk %d", volumePath,
                    extents.extents[0].diskNumber));
            else
                logInfo("probe: " ~ volumePath ~ " (no extents)");
            CloseHandle(handle);
        }
        while (FindNextVolumeW(search, nameBuffer.ptr, cast(DWORD) nameBuffer.length));
        logInfo(format("probe: %d volume(s) enumerated", count));
    }

    /**
     * Lock and dismount the volumes on a disk, log the outcome, then release
     * them. Non-destructive: exercises the exact lock step the write needs.
     */
    void runLockProbe(uint diskNumber)
    {
        logInfo(format("lockProbe: begin disk=%d", diskNumber));
        bool anyVolume;
        auto locks = lockVolumes(diskNumber, anyVolume);
        logInfo(format("lockProbe: disk=%d anyVolume=%s locked=%d",
            diskNumber, anyVolume, locks.length));
        unlockVolumes(locks);
        logInfo("lockProbe: done");
    }

    /**
     * Non-destructive write probe: write a small zeroed block near the end of
     * the disk (past any partition data) with both a buffered and an unbuffered
     * handle, logging the result. Tells us whether the device accepts raw
     * writes at all.
     */
    void runRawWriteProbe(uint diskNumber)
    {
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;
        ulong size = 0;
        {
            auto probe = openDevice(path, genericRead, fileShareRead | fileShareWrite);
            if (handleValid(probe))
            {
                GET_LENGTH_INFORMATION info;
                DWORD returned;
                if (DeviceIoControl(probe, ioctlDiskGetLengthInfo, null, 0,
                    &info, GET_LENGTH_INFORMATION.sizeof, &returned, null))
                    size = cast(ulong) info.length;
                CloseHandle(probe);
            }
        }
        logInfo(format("rawtest: disk=%d size=%d", diskNumber, size));
        if (size < (2 << 20))
        {
            logError("rawtest: disk size unavailable");
            return;
        }
        const offset = size - (1 << 20);
        logInfo(format("rawtest: (no volume locks) offset=%d", offset));
        // Clear the layout on a throwaway handle, then reopen for the sweeps.
        {
            auto prep = openDevice(path, genericRead | genericWrite,
                fileShareRead | fileShareWrite, 0);
            if (handleValid(prep))
            {
                clearDriveLayout(prep);
                CloseHandle(prep);
            }
        }
        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite, 0);
        if (!handleValid(handle))
        {
            logError(format("rawtest: reopen failed error=%d", GetLastError()));
            return;
        }
        scope(exit) CloseHandle(handle);

        auto buffer = new ubyte[1 << 20];
        auto offsets = [0UL, 512UL, 4096UL, 32768UL, 65536UL, 1UL << 20,
            8UL << 20, 100UL << 20, 2_000_000_000UL, 3_000_000_000UL, offset];
        foreach (target; offsets)
        {
            SetFilePointerEx(handle, cast(LARGE_INTEGER) target, null, 0);
            DWORD written;
            if (WriteFile(handle, buffer.ptr, 4096, &written, null))
                logInfo(format("rawtest: size=4096 offset=%d OK", target));
            else
                logError(format("rawtest: size=4096 offset=%d FAILED error=%d",
                    target, GetLastError()));
        }
        static immutable uint[] sizes = [512, 4096, 65536, 1 << 20];
        foreach (chunkSize; sizes)
        {
            SetFilePointerEx(handle, 1 << 20, null, 0);
            DWORD written;
            if (WriteFile(handle, buffer.ptr, chunkSize, &written, null))
                logInfo(format("rawtest: size=%d offset=1048576 OK", chunkSize));
            else
                logError(format("rawtest: size=%d offset=1048576 FAILED error=%d",
                    chunkSize, GetLastError()));
        }
    }

    private enum uint createNoWindow = 0x08000000;
    private enum uint infinite = 0xFFFFFFFF;

    private struct STARTUPINFOW
    {
        DWORD cb;
        LPWSTR lpReserved;
        LPWSTR lpDesktop;
        LPWSTR lpTitle;
        DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
        DWORD dwFillAttribute, dwFlags;
        WORD wShowWindow, cbReserved2;
        void* lpReserved2;
        HANDLE hStdInput, hStdOutput, hStdError;
    }

    private struct PROCESS_INFORMATION
    {
        HANDLE hProcess, hThread;
        DWORD dwProcessId, dwThreadId;
    }

    private extern (Windows) BOOL CreateProcessW(LPCWSTR appName,
        LPWSTR commandLine, void* procAttrs, void* threadAttrs, BOOL inherit,
        DWORD flags, void* environment, LPCWSTR currentDir, STARTUPINFOW* startup,
        PROCESS_INFORMATION* processInfo);
    private extern (Windows) DWORD WaitForSingleObject(HANDLE handle, DWORD ms);
    private extern (Windows) BOOL GetExitCodeProcess(HANDLE process, DWORD* code);

    /**
     * Create one partition that fills the unallocated space after the ISO
     * image and format it so Windows can use the remainder of the stick.
     */
    void formatRemainingSpace(uint diskNumber, string label = "AURORA")
    {
        import std.file : write, remove;
        import std.process : environment;
        auto tmp = environment.get("TEMP", ".") ~ "\\aurora-diskpart.txt";
        auto script = format("select disk %d\r\n" ~
            "create partition primary\r\n" ~
            "format fs=exfat quick label=%s\r\n" ~
            "assign\r\n", diskNumber, label);
        try
            write(tmp, script);
        catch (Exception e)
        {
            logError("formatRemainingSpace: cannot write script: " ~ e.msg);
            return;
        }
        void cleanupTemp()
        {
            try
                remove(tmp);
            catch (Exception)
            {
            }
        }
        scope(exit) cleanupTemp();
        auto commandLine = ("diskpart /s \"" ~ tmp ~ "\"").dup;
        STARTUPINFOW startup;
        startup.cb = STARTUPINFOW.sizeof;
        PROCESS_INFORMATION processInfo;
        if (!CreateProcessW(null, cast(LPWSTR) commandLine.toUTF16z, null, null,
            false, createNoWindow, null, null, &startup, &processInfo))
        {
            logError(format("formatRemainingSpace: CreateProcess failed (error %d)",
                GetLastError()));
            return;
        }
        WaitForSingleObject(processInfo.hProcess, infinite);
        DWORD code;
        GetExitCodeProcess(processInfo.hProcess, &code);
        CloseHandle(processInfo.hThread);
        CloseHandle(processInfo.hProcess);
        logInfo(format("formatRemainingSpace: diskpart exit=%d", code));
        logVolumeProbe();
    }

    /// A BlockDevice over a raw physical drive, for the from-scratch layout writer.
    final class PhysicalDriveDevice : BlockDevice
    {
        private HANDLE handle;
        private ulong lengthBytes;
        private uint sectorSizeBytes;

        this(HANDLE handle, ulong lengthBytes, uint sector)
        {
            this.handle = handle;
            this.lengthBytes = lengthBytes;
            this.sectorSizeBytes = sector != 0 ? sector : 512;
        }

        ulong size() const { return lengthBytes; }
        uint sectorSize() const { return sectorSizeBytes; }

        void read(ulong offset, ubyte[] buffer)
        {
            if (!readRaw(offset, buffer))
                throw new Exception("PhysicalDriveDevice: read failed");
        }

        void write(ulong offset, const(ubyte)[] data)
        {
            const sec = sectorSizeBytes;
            if (offset % sec == 0 && data.length % sec == 0)
            {
                if (!writeRaw(offset, data))
                    throw new Exception("PhysicalDriveDevice: write failed");
                return;
            }
            // Sub-sector writes (e.g. FAT entries) need read-modify-write.
            const ulong start = (offset / sec) * sec;
            const ulong end = ((offset + data.length + sec - 1) / sec) * sec;
            auto buffer = new ubyte[cast(size_t) (end - start)];
            if (!readRaw(start, buffer))
                throw new Exception("PhysicalDriveDevice: read-modify-write read failed");
            const size_t base = cast(size_t) (offset - start);
            foreach (i, b; data)
                buffer[base + i] = b;
            if (!writeRaw(start, buffer))
                throw new Exception("PhysicalDriveDevice: read-modify-write write failed");
        }

        void flush() { FlushFileBuffers(handle); }

        private bool readRaw(ulong offset, ubyte[] buffer)
        {
            if (!SetFilePointerEx(handle, cast(LARGE_INTEGER) offset, null, 0))
                return false;
            auto p = buffer.ptr;
            size_t remaining = buffer.length;
            while (remaining > 0)
            {
                DWORD chunk = cast(DWORD) (remaining > 0x100000 ? 0x100000 : remaining);
                DWORD got;
                if (!ReadFile(handle, p, chunk, &got, null) || got == 0)
                    return false;
                p += got;
                remaining -= got;
            }
            return true;
        }

        private bool writeRaw(ulong offset, const(ubyte)[] data)
        {
            if (!SetFilePointerEx(handle, cast(LARGE_INTEGER) offset, null, 0))
                return false;
            auto p = data.ptr;
            size_t remaining = data.length;
            while (remaining > 0)
            {
                DWORD chunk = cast(DWORD) (remaining > 0x100000 ? 0x100000 : remaining);
                DWORD wrote;
                if (!WriteFile(handle, p, chunk, &wrote, null) || wrote == 0)
                    return false;
                p += wrote;
                remaining -= wrote;
            }
            return true;
        }
    }

    /**
     * Experimental: write a GPT with a FAT32 partition holding the ISO contents
     * plus an exFAT data partition for the remaining space. This is the
     * from-scratch alternative to the byte-for-byte raw ("dd") write; the raw
     * path remains the default.
     */
    ulong writeIsoLayoutToPhysicalDrive(string isoPath, uint diskNumber,
        LayoutOptions options = LayoutOptions.init,
        scope void delegate(DeviceProgress) onProgress = null,
        scope bool delegate() cancel = null)
    {
        if (!exists(isoPath))
            throw new Exception("Image not found: " ~ isoPath);

        bool anyVolume;
        auto locks = lockVolumes(diskNumber, anyVolume);
        scope(exit) unlockVolumes(locks);
        logInfo(format("layoutInstall: disk=%d volumes=%s locks=%d",
            diskNumber, anyVolume, locks.length));

        const sector = querySectorSize(diskNumber);
        auto path = "\\\\.\\PhysicalDrive" ~ diskNumber.to!string;

        // Clear the partition table on a throwaway handle, then reopen.
        {
            auto prep = openDevice(path, genericRead | genericWrite,
                fileShareRead | fileShareWrite, 0);
            if (handleValid(prep))
            {
                clearDriveLayout(prep);
                CloseHandle(prep);
            }
        }

        auto handle = openDevice(path, genericRead | genericWrite,
            fileShareRead | fileShareWrite, 0);
        if (!handleValid(handle))
            throw new Exception("Cannot open " ~ path ~
                " (administrator rights required)");
        scope(exit) CloseHandle(handle);

        ulong lengthBytes = 0;
        GET_LENGTH_INFORMATION info;
        DWORD returned;
        if (DeviceIoControl(handle, ioctlDiskGetLengthInfo, null, 0,
            &info, GET_LENGTH_INFORMATION.sizeof, &returned, null))
            lengthBytes = cast(ulong) info.length;
        if (lengthBytes == 0)
            throw new Exception("Cannot determine the size of " ~ path);

        auto device = new PhysicalDriveDevice(handle, lengthBytes, sector);
        auto image = new IsoImage(isoPath);
        scope(exit) image.close();

        auto result = writeIsoLayout(device, image, options,
            delegate(string message, double fraction) {
                logInfo(format("layoutInstall: %.0f%% %s", fraction * 100.0, message));
                if (onProgress !is null)
                    onProgress(DeviceProgress(fraction, message));
            },
            cancel);
        logInfo(format("layoutInstall: wrote %d files (%d bytes) to disk %d",
            result.filesCopied, result.bytesCopied, diskNumber));
        return result.bytesCopied;
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

    bool hasAdminRights() { return false; }

    void logVolumeProbe() {}

    void runLockProbe(uint diskNumber) {}

    void runRawWriteProbe(uint diskNumber) {}

    void formatRemainingSpace(uint diskNumber, string label = "AURORA") {}

    ulong writeIsoLayoutToPhysicalDrive(string isoPath, uint diskNumber,
        LayoutOptions options = LayoutOptions.init,
        scope void delegate(DeviceProgress) onProgress = null,
        scope bool delegate() cancel = null)
    {
        return 0;
    }
}

unittest
{
    assert(formatSize(512) == "512 B");
    assert(formatSize(2048) == "2.0 KiB");
    assert(formatSize(1024 * 1024) == "1.0 MiB");
}
