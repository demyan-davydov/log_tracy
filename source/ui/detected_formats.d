//! What format detection picks for the file at a path, asked by the File Info page and the menus
//! of "Open as" (to mark that format): read from the first bytes of the file once, remembered while
//! the file stays as it is (its size and time of change), so the pages that ask again and again
//! (a progress of the load, every render of the start screen) read nothing. Only a regular file is
//! read: a pipe or a device would wait.
module ui.detected_formats;

import formats.registry : detectedFormatId, detectionHeadSize;

import std.algorithm : min;

final class DetectedFormats
{
    private struct Known
    {
        ulong size;
        long modified; // stdTime
        string id;
    }

    private Known[string] _known;
    /// The first bytes of the file at a path (replaced by a test)
    private const(ubyte)[] delegate(string path) _readHead;

    this(const(ubyte)[] delegate(string path) readHead = null)
    {
        _readHead = readHead !is null ? readHead : (string path) => readHeadOf(path);
    }

    /// Returns: the id of the format detection picks for the file, "" if it can't be read, is no
    /// regular file or no format fits
    string of(string path)
    {
        import std.file : DirEntry;

        try
        {
            // One stat for the kind, the size and the time of change: the file may be on a slow disk
            auto entry = DirEntry(path);
            if (!entry.isFile)
                return "";
            const size = entry.size;
            const modified = entry.timeLastModified.stdTime;
            if (auto have = path in _known)
                if (have.size == size && have.modified == modified)
                    return have.id;
            const id = detectedFormatId(path, _readHead(path));
            _known[path] = Known(size, modified, id);
            return id;
        }
        catch (Exception)
            return "";
    }
}

private const(ubyte)[] readHeadOf(string path)
{
    import std.stdio : File;

    auto file = File(path, "rb");
    auto head = new ubyte[min(file.size, detectionHeadSize)];
    return file.rawRead(head);
}

version (unittest)
{
    private enum logcatLine = "11-03 14:22:01.123  1234  1250 I Tag: text\n";
}

@("DetectedFormats: the format of a file, read once while the file stays as it is, again when it changes")
unittest
{
    import std.file : append, remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "detected_formats_cache.log");
    write(path, logcatLine);
    scope (exit)
        remove(path);
    int reads;
    auto detected = new DetectedFormats((string p) { ++reads; return cast(const(ubyte)[]) logcatLine; });

    assert(detected.of(path) == "logcat" && detected.of(path) == "logcat");
    assert(reads == 1, "asked twice, read once");
    append(path, logcatLine);
    assert(detected.of(path) == "logcat");
    assert(reads == 2, "the file grew: read again");
}

@("DetectedFormats: nothing for what is not a regular file, a file that is not there or what no format reads")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    int reads;
    auto detected = new DetectedFormats((string p) { ++reads; return cast(const(ubyte)[]) [0x01, 0x00, 0x02]; });
    assert(detected.of(tempDir()) == "" && detected.of(buildPath(tempDir(), "detected_none.log")) == "");
    assert(reads == 0, "a folder and a missing file are not read");

    const path = buildPath(tempDir(), "detected_formats_binary.bin");
    write(path, [0x01, 0x00, 0x02]);
    scope (exit)
        remove(path);
    assert(detected.of(path) == "", "no format reads it");
}

@("DetectedFormats: the real head of a file is what is detected")
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "detected_formats_real.log");
    write(path, logcatLine);
    scope (exit)
        remove(path);
    assert(new DetectedFormats().of(path) == "logcat");
}
