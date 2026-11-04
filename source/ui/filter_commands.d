module ui.filter_commands;

//! The filter commands of the UI, apart from the window so they can be tested.
//! Each one returns an error message for the user, "" on success.

import domain.document : Document;

//! @brief Applies the quick filter of the main view
//! @param json - {column id: value} for the columns of the document; all
//! values empty resets the filter
string applyQuickFilter(Document doc, string json)
{
    import log_core.field_filter : FieldFilter;
    import std.json : JSONType, parseJSON;

    try
    {
        string[string] values;
        foreach (string id, value; parseJSON(json).object)
            if (value.type == JSONType.string)
                values[id] = value.str;

        // Throws if a value doesn't suit its column: the view keeps its filter
        doc.applyViewFilter(FieldFilter.fromValues(doc.columns, values)); // null resets it
        return "";
    }
    catch (Exception e)
        return e.msg;
}

//! @brief Loads a .dlf and runs it as the search of the document
string loadDltFilter(Document doc, string path)
{
    import formats.dlt.log_filter : DltLogFilter;

    if (!DltLogFilter!wchar.canFilter(doc.format))
        return "DLT filters (.dlf) apply to DLT logs only";
    try
    {
        auto filter = new DltLogFilter!wchar();
        filter.load(path);
        doc.applySearchFilter(filter);
        return "";
    }
    catch (Exception e)
        return "Can't load the filter: " ~ e.msg;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

version (unittest)
{
    import domain.log_document : LogDocument;

    //! A document of a temporary file; remove(path) after use
    private LogDocument openTemp(string name, const(ubyte)[] content, out string path)
    {
        import std.file : write, tempDir;
        import std.path : buildPath;

        path = buildPath(tempDir(), name);
        write(path, content);
        return new LogDocument(path);
    }

    private const(ubyte)[] dltContent()
    {
        import formats.dlt.format : buildDltMessage;

        return buildDltMessage("ECU1") ~ buildDltMessage("ECU2");
    }
}

@("applyQuickFilter: reports a value the column can't take, and bad requests")
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : remove;

    string path;
    auto doc = openTemp("filter_commands_quick.dlt", dltContent(), path);
    scope (exit)
    {
        doc.destroy();
        remove(path);
    }

    assert(applyQuickFilter(doc, `{"ecu": "ECU1"}`) == "");
    assert(applyQuickFilter(doc, `{}`) == "", "no values: the filter is reset");

    const error = applyQuickFilter(doc, `{"type": "debug"}`);
    assert(error.canFind("Type"), "the message names the column: " ~ error);
    assert(applyQuickFilter(doc, `{"payload": "(unclosed"}`).length, "an invalid regex");
    assert(applyQuickFilter(doc, `not json`).length);
}

@("loadDltFilter: DLT documents only, and a file that can't be loaded is reported")
unittest
{
    import formats.dlt.log_filter : DltLogFilter;
    import std.algorithm.searching : canFind;
    import std.file : remove, tempDir;
    import std.path : buildPath;

    string textPath, dltPath;
    auto text = openTemp("filter_commands_text.log", cast(const(ubyte)[]) "a line\n", textPath);
    auto dlt = openTemp("filter_commands_dlf.dlt", dltContent(), dltPath);
    const dlfPath = buildPath(tempDir(), "filter_commands.dlf");
    new DltLogFilter!wchar().save(dlfPath);
    scope (exit)
    {
        text.destroy();
        dlt.destroy();
        remove(textPath);
        remove(dltPath);
        remove(dlfPath);
    }

    assert(loadDltFilter(text, dlfPath).canFind("DLT logs only"));
    assert(loadDltFilter(dlt, "/nonexistent/filter.dlf").length, "a failed load is not silent");
    assert(loadDltFilter(dlt, dlfPath) == "");
}
