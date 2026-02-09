module ui.document;

import dlt_core.search;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.dlt;
import ui.app_settings;
import std.stdio;

final class Document
{
    private string _sourcePath; // path to opened document
    private string _fibexPath;
    private SearchEngine _searchEngine;
    private FibexParser _fibexParser;
    private Indexer _currentIndexer;
    private FilterConfig _filterConfig;

    this(string path)
    {
        try
        {
            _sourcePath = path;

            _currentIndexer = new Indexer(path);
            _currentIndexer.scan();
            _searchEngine = new SearchEngine(_currentIndexer);
            _searchEngine._fibex = this._fibexParser;
            writeln("Indexed messages: ", _currentIndexer.totalMessages);
        }
        catch (Exception e)
        {
            writeln("Error indexing: ", e.msg);
            throw e;
        }
    }

    void openFibex(string path)
    {
        try
        {
            _fibexPath = path;
            _fibexParser = new FibexParser();
            _fibexParser.load(_fibexPath);
            if (_searchEngine)
                _searchEngine._fibex = _fibexParser;
        }
        catch (Exception e)
        {
            writeln("Error loading fibex: ", e.msg);
            throw e;
        }
    }

    size_t length() const pure
    {
        return _searchEngine.getLogCount();
    }

    LogItem logItem(size_t index)
    {
        return _searchEngine.getLogItem(index);
    }

    string logItemAsJson(size_t index)
    {
        return _searchEngine.getLogItemAsJson(index);
    }

    int progress() const pure nothrow @nogc
    {
        return _searchEngine.getProgress();
    }
}
