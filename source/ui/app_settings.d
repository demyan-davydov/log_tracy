module ui.app_settings;

import std.json;
import std.file;
import std.stdio;
import std.path;
import std.conv;
import std.array;
import std.algorithm;

struct WindowRect
{
    int left;
    int top;
    int width;
    int height;

    int right() const pure @nogc @property
    {
        return left + width;
    }

    int bottom() const pure @nogc @property
    {
        return top + height;
    }
}

struct FileState
{
    string path;
    int scrollPosition;
}

struct AppSettings
{
    WindowRect windowRect;
    FileState[] files;
    string activeFile;
    string theme;

    this(ref return scope const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.theme = rhs.theme;
    }

    void opAssign(const AppSettings rhs)
    {
        this.windowRect = rhs.windowRect;
        this.files = rhs.files.dup;
        this.activeFile = rhs.activeFile;
        this.theme = rhs.theme;
    }

    bool opEquals(const ref AppSettings rhs) const
    {
        return windowRect == rhs.windowRect &&
            files == rhs.files &&
            activeFile == rhs.activeFile &&
            theme == rhs.theme;
    }

    size_t toHash() const @safe nothrow
    {
        size_t hash = windowRect.hashOf();
        hash = hashOf(files, hash);
        hash = hashOf(activeFile, hash);
        hash = hashOf(theme, hash);
        return hash;
    }
}

static string defaultSettingsPath()
{
    import std.file : thisExePath;
    import std.path : dirName;

    // Get directory of executable, go up one level from resources if needed
    string exeDir = dirName(thisExePath());
    // If we're in resources folder, go up
    if (exeDir.endsWith("resources"))
        exeDir = dirName(exeDir);
    return buildPath(exeDir, "settings.json");
}

static toJSON(AppSettings settings)
{
    JSONValue j;
    j.object = null; // Clear

    JSONValue r = [
        "left": settings.windowRect.left, "top": settings.windowRect.top,
        "width": settings.windowRect.width, "height": settings.windowRect.height
    ];
    j.object["windowRect"] = r;

    JSONValue[] fileArray;
    foreach (f; settings.files)
    {
        JSONValue fv = ["path": f.path];
        fv.object["scrollPosition"] = JSONValue(f.scrollPosition);
        fileArray ~= fv;
    }
    j.object["files"] = JSONValue(fileArray);
    j.object["activeFile"] = JSONValue(settings.activeFile);
    j.object["theme"] = JSONValue(settings.theme);

    return j;
}

static AppSettings loadSettings(string path = defaultSettingsPath())
{
    AppSettings settings;
    // Default values
    settings.windowRect = WindowRect(100, 100, 1200, 800);
    settings.theme = "light";

    writeln("Loading settings from: ", path);
    if (!exists(path))
    {
        return settings;
    }

    try
    {
        string content = readText(path);
        JSONValue j = parseJSON(content);

        if ("windowRect" in j)
        {
            JSONValue r = j["windowRect"];
            settings.windowRect.left = r["left"].integer.to!int;
            settings.windowRect.top = r["top"].integer.to!int;
            settings.windowRect.width = r["width"].integer.to!int;
            settings.windowRect.height = r["height"].integer.to!int;
        }

        if ("files" in j)
        {
            foreach (val; j["files"].array)
            {
                FileState fs;
                fs.path = val["path"].str;
                if ("scrollPosition" in val)
                    fs.scrollPosition = val["scrollPosition"].integer.to!int;
                settings.files ~= fs;
            }
        }
        else if ("openFiles" in j)
        {
            // Migration from old format
            foreach (val; j["openFiles"].array)
            {
                settings.files ~= FileState(val.str, 0);
            }
        }

        if ("activeFile" in j)
        {
            settings.activeFile = j["activeFile"].str;
        }

        if ("theme" in j)
        {
            settings.theme = j["theme"].str;
        }

    }
    catch (Exception e)
    {
        writeln("Error loading settings: ", e.msg);
    }

    return settings;
}

void saveSettings(in ref const(AppSettings) settings, string path = defaultSettingsPath())
{
    import std.string : replace;

    JSONValue j = ["gui": "dlt-explorer"]; // Dummy init
    j.object = null; // Clear

    JSONValue r = [
        "left": settings.windowRect.left, "top": settings.windowRect.top,
        "width": settings.windowRect.width, "height": settings.windowRect.height
    ];
    j.object["windowRect"] = r;

    JSONValue[] fileArray;
    foreach (f; settings.files)
    {
        JSONValue fv = ["path": f.path];
        fv.object["scrollPosition"] = JSONValue(f.scrollPosition);
        fileArray ~= fv;
    }
    j.object["files"] = JSONValue(fileArray);
    j.object["activeFile"] = JSONValue(settings.activeFile);
    j.object["theme"] = JSONValue(settings.theme);

    try
    {
        // Remove unnecessary escape slashes from JSON output
        string jsonStr = j.toPrettyString().replace("\\/", "/");
        std.file.write(path, jsonStr);
        writeln("Settings saved to ", path);
    }
    catch (Exception e)
    {
        writeln("Error saving settings: ", e.msg);
    }
}
