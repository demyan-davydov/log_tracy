module domain.view_status;

import domain.document : Document, DocumentView, OperationStarted, OperationProgress, OperationFinished;

//! @brief Stored state of one document view, driven by the operation events
//! that affect this view. Updated on the UI thread only (from dispatchEvents),
//! so it always matches the events delivered so far.
struct ViewStatus
{
    alias State = DocumentView.State;

    State state = State.Ready;
    float progress = 1.0f; // 0..1, 1 when not building
    string error; // set in State.Error
    /// Operation that brought the view to its current state: the running one
    /// while BuildingIndex, the last one afterwards (None if there was none).
    Document.Operation operation = Document.Operation.None;

    this(State initial)
    {
        state = initial;
        progress = initial == State.Ready ? 1.0f : 0.0f;
    }

    void on(in OperationStarted e)
    {
        operation = e.operation;
        state = State.BuildingIndex;
        progress = 0.0f;
        error = null;
    }

    void on(in OperationProgress e)
    {
        if (state == State.BuildingIndex)
            progress = e.progress;
    }

    void on(in OperationFinished e)
    {
        final switch (e.result)
        {
        case OperationFinished.Result.Completed:
            state = State.Ready;
            progress = 1.0f;
            break;
        case OperationFinished.Result.Cancelled:
            state = State.NotReady; // index is incomplete
            break;
        case OperationFinished.Result.Failed:
            state = State.Error;
            error = e.error;
            break;
        }
    }
}

@("ViewStatus: started -> progress -> completed")
unittest
{
    import domain.document : Document;

    enum op = Document.Operation.BuildOffsetIndex;
    auto status = ViewStatus(ViewStatus.State.NotReady);
    assert(status.state == ViewStatus.State.NotReady && status.progress == 0.0f);

    assert(status.operation == Document.Operation.None);

    status.on(OperationStarted(op));
    assert(status.state == ViewStatus.State.BuildingIndex && status.progress == 0.0f);
    assert(status.operation == op);

    status.on(OperationProgress(op, 0.25f));
    assert(status.progress == 0.25f);

    status.on(OperationFinished(op, OperationFinished.Result.Completed));
    assert(status.state == ViewStatus.State.Ready && status.progress == 1.0f);
    assert(status.operation == op, "the finished operation is kept");

    // Late progress after completion must not reopen the view
    status.on(OperationProgress(op, 0.5f));
    assert(status.state == ViewStatus.State.Ready && status.progress == 1.0f);
}

@("ViewStatus: cancelled and failed operations")
unittest
{
    import domain.document : Document;

    enum op = Document.Operation.BuildSearchIndex;
    ViewStatus status;
    assert(status.state == ViewStatus.State.Ready, "default view status is Ready");

    status.on(OperationStarted(op));
    status.on(OperationProgress(op, 0.4f));
    status.on(OperationFinished(op, OperationFinished.Result.Cancelled));
    assert(status.state == ViewStatus.State.NotReady);
    assert(status.progress == 0.4f, "cancelled view keeps the reached progress");

    status.on(OperationStarted(op));
    status.on(OperationFinished(op, OperationFinished.Result.Failed, "disk error"));
    assert(status.state == ViewStatus.State.Error);
    assert(status.error == "disk error");

    status.on(OperationStarted(op));
    assert(status.state == ViewStatus.State.BuildingIndex && status.error is null,
        "a new operation clears the previous error");
}
