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
        NotReady,
        Ready,
        BuildingIndex,
        Error,
    }

    size_t itemsCount() pure nothrow @nogc const;

    bool fetchItem(size_t index, scope ref DocumentItem item);

    State state() const;

    double progress() const; // return 1.0 if ready
}

interface Document
{
    enum Operation
    {
        None,
        BuildingIndex,
        BuildingFilterIndex,
        BuildingSearchIndex,
    }

    DocumentView mainView();

    DocumentView searchView();

    DocumentId id() const;

    string sourcePath() const;

    string fibexPath() const;

    string filterPath() const;

    void openFibex(string path);

    void applyViewFilter(LogFilter!wchar filter);

    void applySearchFilter(LogFilter!wchar filter);
}
