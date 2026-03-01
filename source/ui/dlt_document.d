module ui.dlt_document;

import ui.document;
import dlt_core.search;
import dlt_core.fibex;
import dlt_core.indexer;
import dlt_core.dlt_protocol;
import ui.app_settings;
import std.stdio;
import std.parallelism : task;
import dlt_core.log_filter : LogFilter;
import dlt_core.log_item : LogItem;

final class DltDocument : Document
{
    private string _sourcePath; // path to opened document
    private string _fibexPath;
    private SearchEngine _searchEngine;
    private FibexParser _fibexParser;
    private Indexer _currentIndexer;
    private LogFilter!wchar _filter;

    this(string path)
    {
        _sourcePath = path;
        _currentIndexer = new Indexer(path);

        auto t = task!scanWorker(this);
        t.executeInNewThread();
    }

    private static void scanWorker(DltDocument self)
    {
        try
        {
            self._currentIndexer.scan();
            self._searchEngine = new SearchEngine(self._currentIndexer);
            if (self._fibexParser)
                self._searchEngine._fibex = self._fibexParser;
            writeln("Indexed messages: ", self._currentIndexer.totalMessages);
        }
        catch (Exception e)
        {
            writeln("Error indexing in thread: ", e.msg);
        }
    }

    ~this()
    {
        if (_currentIndexer)
            _currentIndexer.destroy();

        if (_searchEngine)
            _searchEngine.destroy();

        if (_fibexParser)
            _fibexParser.destroy();

        writeln("Destroyed DltDocument: ", _sourcePath);
    }

    override string sourcePath() const
    {
        return _sourcePath;
    }

    override string fibexPath() const
    {
        return _fibexPath;
    }

    override void openFibex(string path)
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

    override void applyFilter(LogFilter!wchar filter)
    {
        _filter = filter;
        _searchEngine.applyFilter(filter);
    }

    override size_t length() const
    {
        return _searchEngine ? _searchEngine.getLogCount() : 0;
    }

    override LogItem logItem(size_t index)
    {
        return _searchEngine ? _searchEngine.getLogItem(index) : LogItem.init;
    }

    override int progress() const
    {
        if (_searchEngine)
            return 100;
        int p = _currentIndexer ? _currentIndexer.getProgress() : 0;
        if (p >= 100)
            return 99; // Scan done, but SearchEngine initializing
        return p;
    }

    override bool ready() const
    {
        return _searchEngine !is null;
    }
}
