module ui.document;

import dlt_core.search;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.dlt;
import dlt_core.filter : LogFilter;
import dlt_core.log_item;
import ui.app_settings;
import std.stdio;

interface Document
{
    string sourcePath() const;

    string fibexPath() const;

    size_t length() const;

    void openFibex(string path);

    void applyFilter(LogFilter filter);

    LogItem logItem(size_t index);

    int progress() const;

    bool ready() const;

    final string logItemAsJson(size_t index)
    {
        import std.conv : to;
        import std.json;

        const size_t total = length();
        if (index < 0 || index >= total)
            return "{}";

        LogItem item = logItem(index);

        JSONValue j = [
            "index": JSONValue(item.index),
            "offset": JSONValue(item.offset),
            "length": JSONValue(item.length),
            "timestamp": JSONValue(item.timestamp),
            "ecu": JSONValue(item.ecu),
            "appId": JSONValue(item.appId),
            "ctxId": JSONValue(item.ctxId),
            "level": JSONValue(to!string(item.level)),
            "type": JSONValue(toString(item.type)),
            "payload": JSONValue(item.payload)
        ];

        return j.toString();
    }
}
