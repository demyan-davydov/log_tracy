module domain.background_operation;

import std.parallelism : Task, TaskPool;
import std.typecons : scoped, Unique;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;

struct BackgroundOperation
{
    private shared bool _cancelFlag = false; // cancel current operation
    private shared float _progress = 0.0f; // building index

    private Mutex _mutex; // mutex for building indexes
    private Unique!TaskPool _taskPool;

    enum Status
    {
        Started,
        Progress,
        Finished,
        Cancelled,
    }

    this(int)
    {
        _mutex = new Mutex();
        _taskPool = Unique!TaskPool();
    }

    ~this()
    {

    }

    private void runTask(Args...)(CurrentOperation op, bool delegate(Args) dg, scope Args args)
    {
        synchronized (_mutex)
        {
            if (_currentOperation != CurrentOperation.None)
                return;
            _currentOperation = op;
        }

        atomicStore(_cancelFlag, false);
        atomicStore(_progress, 0.0f);

        auto currentTask = task(() {
            dg(args);

            synchronized (_mutex)
            {
                atomicStore(_progress, 1.0f);
                _currentOperation = CurrentOperation.None;
            }
        });

        _taskPool.put(currentTask);
    }

    void cancelCurrentOperation()
    {
        atomicStore(_cancelFlag, true);
    }
}
