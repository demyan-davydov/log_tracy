//! ProgressReporter: the progress of the operations a pass of LogIndex runs, throttled and
//! published in one event (events of one type override each other in the queue).
module domain.index.progress;

import domain.document : Document, OperationProgress;
import utils.background_slot : BackgroundSlot;
import utils.event_bus.event_bus_interface : SignalProducer;

//! Minimal progress change worth an event
enum float progressStep = 0.01f;

struct ProgressReporter
{
    alias Operation = Document.Operation;

    SignalProducer events;
    BackgroundSlot.Ctx* ctx;
    private float[Operation.max + 1] published = -1;

    this(SignalProducer events, BackgroundSlot.Ctx* ctx)
    {
        this.events = events;
        this.ctx = ctx;
    }

    //! The progress of the load, the filter and the search, 0..1; NaN for one that isn't
    //! reported. Published when one of them moved by progressStep, reached its end or
    //! went back
    void report(float load, float filter, float search)
    {
        float[Operation.max + 1] values;
        values[Operation.BuildOffsetIndex] = load;
        values[Operation.BuildFilterIndex] = filter;
        values[Operation.BuildSearchIndex] = search;
        bool worth = false;
        foreach (i, value; values)
        {
            if (value != value) // not running
                continue;
            ctx.progress = value;
            if ((value >= 1.0f && published[i] < 1.0f) || value - published[i] >= progressStep
                || value < published[i])
                worth = true;
        }
        if (!worth)
            return;
        foreach (i, value; values)
            if (value == value)
                published[i] = value;
        events.publish(OperationProgress(values));
    }
}
