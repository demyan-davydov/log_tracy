module ui.document;

import dlt_core.search;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.dlt;
import ui.app_settings;
import std.stdio;

interface Document
{
    size_t length() const;

    LogItem logItem(size_t index);

    string logItemAsJson(size_t index);

    int progress() const;
}
