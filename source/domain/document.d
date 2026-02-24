module domain.document;

import dlt_core.dlt_source;
import dlt_core.decoded_message;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.log_filter : LogFilter;
import dlt_core.dlt_protocol : LogLevel, MessageType;

import domain.document_id;
import domain.document_item;

interface DocumentView
{
    enum State
    {
        Ready,
        NotReady,
        BuildingIndex,
        Error,
    }

    size_t itemsCount() pure nothrow @nogc const;

    bool fetchItem(size_t index, out DocumentItem item);

    State state() const;

    double progress() const; // return 1.0 if ready
}

interface Document
{
    enum State
    {
        Ready,
        NotReady,
        BuildingIndex,
        BuildingFilterIndex,
        BuildingSearchIndex,
        Error,
    }

    enum Operation
    {
        None,
        BuildingIndex,
        BuildingFilterIndex,
        BuildingSearchIndex,
    }

    DocumentView rawView();

    DocumentView filteredView();

    DocumentView searchView();

    DocumentId id() const;

    string sourcePath() const;

    string fibexPath() const;

    string filterPath() const;

    void openFibex(string path);

    void applyViewFilter(LogFilter!wchar filter);

    void applySearchFilter(LogFilter!wchar filter);

    /*
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
    }*/
}
