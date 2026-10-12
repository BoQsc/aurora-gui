module auroraopencode.download;

import auroraopencode.transferprogress;
import core.time : MonoTime, msecs;
import std.conv : to;
import std.digest.sha : SHA256;
import std.digest : toHexString;
import std.file : exists, getSize, mkdirRecurse, readText, remove, rename, write;
import std.json : JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import std.string : splitLines, strip, toLower, startsWith, indexOf;
import std.utf : toUTF16z, toUTF8;

public struct DownloadOutcome { bool failed; string output; }

private void check(bool delegate() cancelled)
{
    if (cancelled !is null && cancelled()) throw new Exception("Stopped: operation cancelled.");
}

public string checksumFile(string path, bool delegate() cancelled = null,
    void delegate(string) observer = null)
{
    auto file = File(path, "rb");
    auto buffer = new ubyte[1024 * 1024];
    SHA256 digest;
    TransferProgress progress;
    progress.phase = "Checking SHA-256";
    progress.path = path;
    progress.totalBytes = getSize(path);
    progress.totalFiles = 1;
    progress.totalsKnown = true;
    const started = MonoTime.currTime;
    MonoTime nextReport = started;
    while (progress.bytesDone < progress.totalBytes)
    {
        check(cancelled);
        const remaining = progress.totalBytes - progress.bytesDone;
        auto chunk = file.rawRead(buffer[0 .. cast(size_t) (remaining < buffer.length ? remaining : buffer.length)]);
        if (!chunk.length) break;
        digest.put(chunk);
        progress.bytesDone += chunk.length;
        if (observer !is null && MonoTime.currTime >= nextReport)
        {
            const elapsed = (MonoTime.currTime - started).total!"msecs";
            progress.bytesPerSecond = elapsed > 0 ? cast(double) progress.bytesDone * 1000 / elapsed : 0;
            progress.remainingSeconds = progress.bytesPerSecond > 0 && progress.bytesDone <= progress.totalBytes ?
                (progress.totalBytes - progress.bytesDone) / progress.bytesPerSecond : -1;
            observer(encodeTransferProgress(progress));
            nextReport = MonoTime.currTime + 150.msecs;
        }
    }
    check(cancelled);
    if (progress.bytesDone != progress.totalBytes || getSize(path) != progress.totalBytes)
        throw new Exception("File size changed while computing SHA-256: " ~ path);
    progress.filesDone = 1;
    if (observer !is null) observer(encodeTransferProgress(progress));
    return toHexString(digest.finish()).toLower();
}

public bool validSha256(string value)
{
    if (!value.length) return true;
    if (value.length != 64) return false;
    foreach (c; value) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    return true;
}

version (Windows)
{
    import core.sys.windows.windows : HANDLE, DWORD, CreateFileW, CloseHandle,
        GENERIC_WRITE, OPEN_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, INVALID_HANDLE_VALUE,
        MoveFileExW, GetLastError;
    import core.sys.windows.wininet;

    private string headers(HINTERNET request)
    {
        wchar[16384] buffer;
        DWORD length = cast(DWORD) (buffer.length * 2);
        if (!HttpQueryInfoW(request, HTTP_QUERY_RAW_HEADERS_CRLF, buffer.ptr, &length, null))
            throw new Exception("Could not read HTTP response headers.");
        return toUTF8(buffer[0 .. length / 2]);
    }

    private string header(string raw, string name)
    {
        foreach (line; raw.splitLines())
            if (line.toLower().startsWith(name.toLower() ~ ":")) return line[name.length + 1 .. $].strip();
        return "";
    }

    public DownloadOutcome downloadFile(string url, string path, string expectedSha256 = "",
        bool resume = true, bool delegate() cancelled = null, void delegate(string) observer = null,
        uint timeoutMs = 10000)
    {
        const partial = path ~ ".aurora-download.part";
        const metaPath = partial ~ ".json";
        bool partialOwned;
        try
        {
            if (!(url.startsWith("https://") || url.startsWith("http://")) || url.indexOf("\r") >= 0 || url.indexOf("\n") >= 0)
                throw new Exception("download requires an HTTP(S) URL.");
            if (!validSha256(expectedSha256)) throw new Exception("sha256 must contain exactly 64 hexadecimal characters.");
            check(cancelled);
            if (exists(path)) throw new Exception("Destination already exists; nothing was overwritten: " ~ path);
            mkdirRecurse(dirName(path));
            auto lock = CreateFileW((partial ~ ".lock").toUTF16z, GENERIC_WRITE, 0,
                null, OPEN_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, null);
            if (lock == INVALID_HANDLE_VALUE) throw new Exception("Another download owns this destination.");
            scope (exit) CloseHandle(lock);
            JSONValue meta;
            ulong offset;
            string validator;
            if (exists(partial))
            {
                if (!exists(metaPath) || getSize(metaPath) > 32768)
                    throw new Exception("An unrecognized partial file exists; inspect it before retrying: " ~ partial);
                meta = parseJSON(readText(metaPath));
                if (meta["url"].str != url || meta["sha256"].str != expectedSha256.toLower())
                    throw new Exception("Partial file belongs to another URL or checksum; use a different destination.");
                partialOwned = true;
                validator = meta["validator"].str;
                if (resume && (validator.length || expectedSha256.length)) offset = getSize(partial);
            }
            TransferProgress progress;
            progress.phase = "Connecting download";
            progress.path = path;
            progress.bytesDone = offset;
            progress.totalFiles = 1;
            if (observer !is null) observer(encodeTransferProgress(progress));
            auto session = InternetOpenW("Aurora OpenCode"w.ptr, INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0);
            if (session is null) throw new Exception("Could not open the Windows HTTP client.");
            scope (exit) InternetCloseHandle(session);
            timeoutMs = timeoutMs < 1000 ? 1000 : timeoutMs > 60000 ? 60000 : timeoutMs;
            foreach (option; [INTERNET_OPTION_CONNECT_TIMEOUT, INTERNET_OPTION_RECEIVE_TIMEOUT, INTERNET_OPTION_SEND_TIMEOUT])
                InternetSetOptionW(session, option, &timeoutMs, uint.sizeof);
            string requestHeaders = "Accept-Encoding: identity\r\n";
            if (offset)
            {
                requestHeaders ~= "Range: bytes=" ~ to!string(offset) ~ "-\r\n";
                if (validator.length) requestHeaders ~= "If-Range: " ~ validator ~ "\r\n";
            }
            auto request = InternetOpenUrlW(session, url.toUTF16z, requestHeaders.toUTF16z,
                cast(DWORD) requestHeaders.length, INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE |
                INTERNET_FLAG_NO_UI | INTERNET_FLAG_NO_COOKIES | INTERNET_FLAG_NO_AUTH, 0);
            if (request is null) throw new Exception("Could not connect or follow the download redirect (Windows " ~ to!string(GetLastError()) ~ ").");
            scope (exit) InternetCloseHandle(request);
            check(cancelled);
            DWORD status, length = DWORD.sizeof;
            if (!HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &status, &length, null))
                throw new Exception("Could not read HTTP status.");
            const raw = headers(request);
            bool alreadyComplete;
            ulong bodyLength;
            const lengthHeader = header(raw, "Content-Length");
            if (lengthHeader.length) bodyLength = to!ulong(lengthHeader);
            if (status == 206)
            {
                if (validator.length && !expectedSha256.length &&
                    validator != header(raw, "ETag") && validator != header(raw, "Last-Modified"))
                    throw new Exception("Cannot validate the resumed resource; retry with resume=false or an expected SHA-256.");
                const range = header(raw, "Content-Range");
                const expectedPrefix = "bytes " ~ to!string(offset) ~ "-";
                if (!offset || !range.startsWith(expectedPrefix) || range.indexOf("/") < 0)
                    throw new Exception("Server returned an unexpected partial-content range.");
                const total = range[range.indexOf("/") + 1 .. $];
                if (total != "*") { progress.totalBytes = to!ulong(total); progress.totalsKnown = true; }
            }
            else if (status == 416 && offset && header(raw, "Content-Range") == "bytes */" ~ to!string(offset) &&
                (expectedSha256.length || (validator.length &&
                    (validator == header(raw, "ETag") || validator == header(raw, "Last-Modified")))))
            {
                alreadyComplete = true;
                progress.totalBytes = offset;
                progress.totalsKnown = true;
            }
            else if (status == 200)
            {
                // A changed resource or a server ignoring Range restarts safely.
                offset = 0;
                progress.totalBytes = bodyLength;
                progress.totalsKnown = lengthHeader.length > 0;
            }
            else throw new Exception("Download returned HTTP " ~ to!string(status) ~ "; partial data was kept for a retry.");
            validator = header(raw, "ETag");
            if (validator.startsWith("W/")) validator = "";
            if (!validator.length) validator = header(raw, "Last-Modified");
            meta["url"] = url;
            meta["sha256"] = expectedSha256.toLower();
            meta["validator"] = validator;
            write(metaPath, meta.toString());
            partialOwned = true;
            auto output = File(partial, offset ? "ab" : "wb");
            progress.bytesDone = offset;
            progress.phase = offset ? "Resuming download" : "Downloading";
            auto buffer = new ubyte[1024 * 1024];
            const started = MonoTime.currTime;
            MonoTime nextReport = started;
            while (!alreadyComplete)
            {
                check(cancelled);
                DWORD received;
                if (!InternetReadFile(request, buffer.ptr, cast(DWORD) buffer.length, &received))
                    throw new Exception("Download connection failed (Windows " ~ to!string(GetLastError()) ~ "); retry to resume.");
                if (!received) break;
                output.rawWrite(buffer[0 .. received]);
                progress.bytesDone += received;
                if (observer !is null && MonoTime.currTime >= nextReport)
                {
                    const elapsed = (MonoTime.currTime - started).total!"msecs";
                    progress.bytesPerSecond = elapsed > 0 ? cast(double) (progress.bytesDone - offset) * 1000 / elapsed : 0;
                    progress.remainingSeconds = progress.bytesPerSecond > 0 && progress.totalsKnown && progress.bytesDone <= progress.totalBytes ?
                        (progress.totalBytes - progress.bytesDone) / progress.bytesPerSecond : -1;
                    observer(encodeTransferProgress(progress));
                    nextReport = MonoTime.currTime + 150.msecs;
                }
            }
            output.close();
            if (progress.totalsKnown && progress.bytesDone != progress.totalBytes)
                throw new Exception("Download ended before the expected size; retry to resume.");
            const digest = checksumFile(partial, cancelled, observer is null ? null : (string text) {
                TransferProgress update;
                if (decodeTransferProgress(text, update))
                {
                    update.path = path;
                    observer(encodeTransferProgress(update));
                }
                else observer(text);
            });
            if (expectedSha256.length && digest != expectedSha256.toLower())
            {
                remove(partial);
                remove(metaPath);
                partialOwned = false;
                throw new Exception("SHA-256 mismatch; rejected data was removed. Destination was not created.");
            }
            check(cancelled);
            if (!MoveFileExW(partial.toUTF16z, path.toUTF16z, 0))
                throw new Exception("Could not install the completed download; an existing destination was not overwritten.");
            partialOwned = false;
            string cleanupNote;
            try remove(metaPath);
            catch (Exception) cleanupNote = "\nDownload completed; its unused partial metadata could not be removed.";
            progress.phase = "Download complete";
            progress.bytesDone = getSize(path);
            progress.totalBytes = progress.bytesDone;
            progress.totalsKnown = true;
            progress.filesDone = 1;
            progress.remainingSeconds = 0;
            if (observer !is null) observer(encodeTransferProgress(progress));
            return DownloadOutcome(false, "Downloaded " ~ path ~ " (" ~ transferBytes(progress.bytesDone) ~
                ").\nSHA-256: " ~ digest ~ (expectedSha256.length ? "\nChecksum matched." : "\nNo expected checksum was supplied.") ~ cleanupNote);
        }
        catch (Exception error)
            return DownloadOutcome(true, "Error: " ~ error.msg ~ (partialOwned ?
                "\nPartial download kept at: " ~ partial ~ "\nRetry the same download call to resume or restart safely." : ""));
    }
}
else
{
    public DownloadOutcome downloadFile(string url, string path, string expectedSha256 = "",
        bool resume = true, bool delegate() cancelled = null, void delegate(string) observer = null,
        uint timeoutMs = 10000)
    {
        return DownloadOutcome(true, "Error: native downloads currently require Windows. Use a supervised run with curl on this platform.");
    }
}
