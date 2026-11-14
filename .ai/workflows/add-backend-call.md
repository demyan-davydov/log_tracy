# Adding a Backend Call

Background: `.ai/knowledge/architecture.md` (Script ↔ Backend).

## A Call from the Script

1. Tests first: the behaviour as a unittest of `AppSession` (`ui/app_session`), or of the
   Sciter-free module that owns it (`ui/filter_commands`, ...).
2. Implement it as a method of the session. A document's call takes its id first. An error for
   the user is a `uiText` template in a `UiTextException` (`.ai/knowledge/i18n.md`).
3. In `MainWindow.handleEvent` (`ui/main_window`) add a `case` that only reads the parameters,
   calls the session and answers. No logic in the window.
4. In `resources/backend.js` add one function for the xcall; JSON results come parsed. Add its
   case to `tests/js/backend.test.mjs`. The script calls the backend only through it.
   `tests/js/backend-calls.test.mjs` fails while a name is on one side only (a `case` no
   function of `backend.js` calls, or the reverse): a call removed goes from both.

## A Change the Backend Tells the Script

- The session queues a `callScript` of a global function of the script (`onMainViewChanged`,
  ...); `MainWindow.onIdle()` sends the queue. Never call the script from inside an xcall.
- A change of the settings only marks them changed; `onIdle()` writes them.

## A New File in resources/

- Add it to the list of `ui/app_resources` (a unittest fails until it is); the icons are not
  built in.
- Its texts follow `.ai/knowledge/i18n.md`; run `node scripts/utils/i18n-extract.mjs` to update the
  catalogs.
- A pure module gets its tests in `tests/js/<name>.test.mjs`.
- Rebuild to see it in the app.
