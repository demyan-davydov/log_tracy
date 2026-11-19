//! A table's two ears: its model and its layout, and the listening to them while it lives, let go of when it is
//! disposed. Pure.
module ptable.subscriptions;

import ptable.layout : ColumnLayout, LayoutChange;
import ptable.model : ModelChange, TableModel;

struct Subscriptions
{
    private TableModel _model;
    private ColumnLayout _layout;
    private size_t _modelHandle, _layoutHandle;
    private bool _listening;

    /// The ears of `model` and `layout`; they hear nothing before `listen`
    this(TableModel model, ColumnLayout layout)
    {
        _model = model;
        _layout = layout;
    }

    TableModel model() { return _model; }
    ColumnLayout layout() { return _layout; }

    /// Listens to the model and the layout
    void listen(void delegate(const ModelChange) onModel, void delegate(const LayoutChange) onLayout)
    {
        detach(); // a second listen does not leave the first one listening
        _modelHandle = _model.subscribe(onModel);
        _layoutHandle = _layout.subscribe(onLayout);
        _listening = true;
    }

    /// Lets go of both
    void detach()
    {
        if (!_listening)
            return;
        _model.unsubscribe(_modelHandle);
        _layout.unsubscribe(_layoutHandle);
        _listening = false;
    }
}

@("Subscriptions: the ears hear the model and the layout from `listen` until detached, a second listen or detach is harmless")
unittest
{
    import ptable.layout : ColumnLayout;
    import ptable.model : NumbersModel;

    auto model = new NumbersModel(5);
    auto layout = new ColumnLayout;
    auto ears = Subscriptions(model, layout);
    assert(ears.model is model && ears.layout is layout);
    ears.detach(); // nothing listened to
    int heardModel, heardLayout;
    ears.listen((const ModelChange c) { ++heardModel; }, (const LayoutChange c) { ++heardLayout; });
    model.append(1);
    layout.setWidth("n", 40);
    assert(heardModel == 1 && heardLayout == 1);
    ears.listen((const ModelChange c) { ++heardModel; }, (const LayoutChange c) { ++heardLayout; });
    model.append(1);
    assert(heardModel == 2, "the first listen was let go: one listener, not two");
    ears.detach();
    ears.detach();
    model.append(1);
    layout.setWidth("n", 50);
    assert(heardModel == 2 && heardLayout == 1, "nobody listens any more");
}
