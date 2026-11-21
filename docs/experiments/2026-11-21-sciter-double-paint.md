# One requestPaint(), two paints of the whole window (Sciter 6.0.5.5, macOS)

A report for the author of Sciter. The two repro pages, `double-paint.htm` and `clip.htm`, are at the end: save each
as a file and open it in `scapp`.

## Environment

- Sciter 6.0.5.5, `scapp` and `libsciter.dylib` of the SDK (`bin/macosx`), default graphics layer
- macOS 27.2 (26B123), Apple M1 Pro, a Retina screen

## What happens

One `element.requestPaint()` (or `SciterRefreshElementArea` / `SciterUpdateElement` from the C API) makes Sciter paint
the whole window twice, the second time 1–2 ms after the first. Every element that paints itself gets its
`paintContent` (`DRAW_CONTENT` in a native behavior) twice, also elements that nothing asked to repaint.

The repro counts the calls of `paintContent` of one element after a single `requestPaint()`, twenty times with 300 ms
between them. `scapp double-paint.htm`, started from Finder or a shell without a terminal, shows:

```
two paints in 15 of 20 rounds
round 1: 1 paint(s) after one requestPaint(), at +0 ms
round 2: 2 paint(s) after one requestPaint(), at +1, +3 ms
round 3: 2 paint(s) after one requestPaint(), at +1, +2 ms
...
round 19: 2 paint(s) after one requestPaint(), at +0, +1 ms
round 20: 2 paint(s) after one requestPaint(), at +0, +1 ms
```

Two runs both gave 15 of 20. In our application (a log viewer that paints its tables in native behaviors, `DRAW_CONTENT`),
every one-off refresh paints twice: 5 of 5 for `SciterRefreshElementArea`, `SciterUpdateElement` and `requestPaint()`.
The second paint stays when the handler only fills its box, and with `SCITER_SET_GFX_LAYER` set to CG (1) or to Skia
raster (4).
Frames asked by `SciterRequestAnimationFrameEvent` come once each.

## Both paints cover the whole window

`clip.htm` asks one element (`#asked`) to repaint once and has every paint after it fill the whole box
with the color of its number: the first green, the second red, any later one blue. A second element (`#other`) that
nothing asks to repaint does the same. The counts go to the window's caption, not to the DOM.

In four runs out of four the caption says `asked painted 2, other painted 2`, and both boxes are entirely red on the
screen: no pixel of green is left, so the second paint is not clipped to a smaller area. It repaints the whole content
of every element, also of the one nobody asked. No blue: changing the caption causes no third paint.

## Where the two paints come from

Stacks taken in the `DRAW_CONTENT` handler of our element (the frames inside `view::paint`, the element tree, cut out):

First paint: Sciter's own iteration.

```
html::view::paint(html::element*, bool)
xskia::app_factory() + 11820
xskia::app_factory() + 12620
xskia::BackendDevice::render(std::function<bool (xskia::graphics*)>, gool::geom::rect_t<int>, void*)
xskia::app_factory() + 9680
tool::async::dispatch::request_idle()
html::iwindow::handle_run_iteration(bool)
wing::runIteration()
xwing::application::heartbit(bool)
SciterExecImp
```

Second paint: Core Animation has the view's backing layer display at the end of the run loop iteration, and Sciter
renders the window again.

```
html::view::paint(html::element*, bool)
xskia::app_factory() + 11820
xskia::app_factory() + 12620
xskia::BackendDevice::render(std::function<bool (xskia::graphics*)>, gool::geom::rect_t<int>, void*)
xskia::app_factory() + 9680
tool::async::dispatch::request_idle()
html::iwindow::handle_event(wing::event*)
wing::internal::notifyWindowPaint(wing::internal::window*, bool)
wing::internal::IconifyWindowCocoa(wing::internal::window*) + 3264
AppKit _NSViewUpdateLayer
AppKit -[NSViewBackingLayer display]
QuartzCore CA::Layer::display_if_needed(CA::Transaction*)
QuartzCore CA::Context::commit_transaction(CA::Transaction*, double, double*)
QuartzCore CA::Transaction::commit()
QuartzCore CA::Transaction::flush_as_runloop_observer(bool)
CoreFoundation __CFRunLoopDoObservers
...
AppKit -[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:]
wing::internal::WaitEventsTimeoutCocoa(double)
xwing::application::heartbit(bool)
SciterExecImp
```

## Why it matters

The window is painted whole on every refresh: a refresh of a small area still has every element of the window paint
all of its content (what a handler leaves out comes out blank, not kept), so there is no way to make a small change
cheap. The second paint doubles that cost for each hover, selection or other one-off change. For us it is ~1.2 ms of
our own paint per pass for a table of 20 rows, and both tables of the window paint twice.

Drawing the content into an image once and blitting it on the second pass doesn't help: inside `DRAW_CONTENT`,
`gCreate` on an image answers `GRAPHIN_NOTSUPPORTED`, and drawing through `imagePaint` costs about three times drawing
on the screen.

## Expected

One paint per refresh: either Sciter's own render or the layer's display, not both. Or, if both are needed, the second
one could reuse what the first rendered.

## double-paint.htm

```html
<html>
<head>
<title>One requestPaint, two paints</title>
<style>
  #box { width: 300px; height: 200px; background: #eee; }
</style>

</head>
<body>
  <div #box></div>
  <pre #log></pre>
<script>
  const box = document.$("#box");
  let paints = [];
  let asked = 0;

  // the results are shown at the end only: a change of the DOM during the rounds would repaint the box too
  const results = [];
  function report(text) {
    console.log(text);
    results.push(text);
  }

  // count every paint of the element's content and when it came
  box.paintContent = function(gfx) {
    paints.push(Date.now() - asked);
    gfx.fillStyle = "#c33";
    gfx.fillRect(10, 10, 100, 50);
  };

  // let the window settle, then ask for one repaint at a time, twenty times
  let round = 0;
  function ask() {
    if (round > 0)
      report(`round ${round}: ${paints.length} paint(s) after one requestPaint(), at +${paints.join(", +")} ms`);
    if (++round > 20) {
      const twice = results.filter(r => r.includes(": 2 paint")).length;
      document.$("#log").textContent = `two paints in ${twice} of ${results.length} rounds\n` + results.join("\n");
      return;
    }
    paints = [];
    asked = Date.now();
    box.requestPaint();
    setTimeout(ask, 300);
  }
  setTimeout(ask, 1000);
</script>
</body>
</html>
```

## clip.htm

```html
<html>
<head>
<title>clip check</title>
<style>
  div { width: 300px; height: 200px; background: #eee; margin: 8px; }
</style>
</head>
<body>
  <div #asked></div>
  <div #other></div>
<script>
  // After one requestPaint() of #asked, every paint fills the whole box with the color of its number: 1 green, 2 red,
  // 3 and more blue. What stays on the screen shows how much of the box the last paint covered. #other is never asked:
  // its paints are counted the same way. The counts go to the caption, not to the DOM, which would repaint again.
  const colors = ["#3a3", "#c33", "#33c"];
  const asked = document.$("#asked"), other = document.$("#other");
  let counting = false;
  const counts = { asked: 0, other: 0 };

  function painter(name) {
    return function(gfx) {
      if (!counting)
        return;
      const n = ++counts[name];
      gfx.fillStyle = colors[Math.min(n, 3) - 1];
      gfx.fillRect(0, 0, 300, 200);
    };
  }
  asked.paintContent = painter("asked");
  other.paintContent = painter("other");

  setTimeout(() => {
    counting = true;
    asked.requestPaint();
    setTimeout(() => {
      // a paint the caption itself may cause is counted too (blue): it is told by the colors, not by the caption
      Window.this.caption = `asked painted ${counts.asked}, other painted ${counts.other}`;
    }, 300);
  }, 1000);
</script>
</body>
</html>
```
