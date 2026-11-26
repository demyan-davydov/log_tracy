# 6.0.5.6, macOS: `<select>` lists and context menus open behind their window

A report for the author of Sciter. The repro page is at the end: save it as a file and open it in `scapp`.

## Environment

- Sciter 6.0.5.6, `scapp` and `libsciter.dylib` of the SDK (`bin/macosx`)
- macOS 27.2 (26B123), Apple M1 Pro

## What happens

The drop-down list of a `<select>` and a context menu given by `evt.source` in `contextmenu` are not seen. A text
field's own context menu is not seen either (checked in `scapp`). The same page in 6.0.5.5 shows the first two.

The events look normal: `popuprequest`, `popupready` and later `popupdismissed` all arrive. The popup windows are in
fact created, but they are **ordered behind the parent window**: in the order of the on-screen windows
(`CGWindowListCopyWindowInfo` with `kCGWindowListOptionOnScreenOnly`) each of them comes after the window it was opened
from, from the first opening on.

`element.popup()` from script came in front in `scapp`. In our application (also native menus and dialogs) the first
few popups opened that way were behind too.

`<button type="menu">` shows its menu.

## Steps

1. Click the `<select>`: no list.
2. Right-click the grey block: no menu.
3. Click the button: the popup opens.

## What helps on our side

We make every popup window a child of the window under it (`[owner addChildWindow:popup ordered:NSWindowAbove]`) from a
run loop observer. With that all the popups above show, in modal dialogs too. The popup windows we see have the class
`Window`, the style mask 32772 (no title bar), level 0 and no parent window.

One thing remains: a very quick second press on a `<select>` is sometimes lost. We have not checked whether it comes
from the engine or from our workaround.

## By the way

The double paint of every change, reported earlier, is fixed in 6.0.5.6 for me. Thank you!

## popups.htm

```html
<html>
<head>
<title>popups behind</title>
<style>
  body { padding: 16dip; }
  select, button { margin-bottom: 12dip; }
  #area { width: 300dip; height: 80dip; background: #eee; padding: 8dip; margin-bottom: 12dip; }
</style>
</head>
<body>
  <div><select><option>one</option><option>two</option><option>three</option></select></div>
  <div #area>right click here</div>
  <div><input|text value="right click here too" size="30" /></div>
  <div><button #open>popup by script</button></div>
<script>
  document.$("#area").on("contextmenu", evt => {
    evt.source = Element.create(<menu class="context"><li>first item</li><li>second item</li></menu>);
    return true;
  });
  const button = document.$("#open");
  button.on("click", () => button.popup(Element.create(<menu><li>item</li></menu>), { anchorAt: 1, popupAt: 7 }));
</script>
</body>
</html>
```
