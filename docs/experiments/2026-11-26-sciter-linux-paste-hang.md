# 6.0.5.6, Linux: pasting text copied in the same window hangs the application

A report for the author of Sciter.

## Environment

- Sciter 6.0.5.6, `libsciter.so` of the SDK (`bin/linux/arm64`)
- Linux arm64 in a virtual machine: DISTRIBUTION AND VERSION, WAYLAND OR X11
- My own application. It pumps the loop itself: `while (SciterExec(SCITER_APP_LOOP_ITERATION, 0, 0))`

## What happens

I copy some text in a window of my application and paste it into a text input of the same window: the application
hangs.

- The copied text itself is fine: it pastes normally into a terminal.
- Text copied in another program pastes into my inputs normally.
- It happens with text copied from different places of the window: from my table (I put it on the clipboard with
  `Clipboard.writeText`) and from a panel with information about a file.

So it looks as if only reading a clipboard that the process owns itself hangs. My guess, not checked: the engine waits
for the result of `gdk_clipboard_read_async` in a way that does not let the same process provide the data.

## What I have not checked

- I have not reproduced it in `usciter` or `scapp`, only in my application, so my own message loop may play a part.
- I have no stack of the hung process.
- I don't know whether 6.0.5.5 did the same.

## A page to try

I have not run it. It does what my application does: press the button, then paste into the input.

```html
<html>
<head>
<title>paste hang</title>
</head>
<body>
  <button>copy "abc"</button>
  <input|text />
<script>
  document.on("click", "button", () => Clipboard.writeText("abc"));
</script>
</body>
</html>
```
