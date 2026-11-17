# UX Rules

## Scope

How the interface behaves and looks: the requirements the user stated or confirmed, gathered
since the tab strip redesign (2026-11-04). Visual standards (spacing scale, radii, typography)
are in `docs/ui-guidelines.md`; code rules in `.ai/rules/ui.md`.

## Keeping This File

- A requirement the user states that is general for the project (not a one-off fix) is added
  here in the same change, and the user is told in one line what was added.
- Before acting on a new requirement, check it against this file. If it contradicts an entry,
  ask the user at once which one wins, then update the file.
- General rules are defaults; an element with a special role can have its own rule, stated by
  the user.

## General Principles

1. **Follow common conventions.** Behaviour follows widely accepted standards; Chrome is the
   reference for tabs. The user's explicit decisions override the reference.
2. **Keep familiar positions.** Controls stay where the user is used to them: the "+" button is
   on the left of the tabs, though Chrome puts it on the right.
3. **No duplicate controls.** An action available in the app menu doesn't get a toolbar button
   too (there is no top toolbar). Exception: "+" in the tab strip. Actions that belong to a
   panel's content live in that panel (Load Filter next to the filters on their page; Load
   File, Load Folder and Unload FIBEX on the File Info page of a DLT log, under the path of
   the FIBEX).
4. **Settings, not quick toggles.** Rarely changed preferences (the theme) live in Settings; no
   separate toggle button or menu item.
5. **Hide what can't be used.** Panels that only work with a document (filters, document view,
   search, results) are not shown without one; a single placeholder replaces all of them.
   Anything that must work before a document is opened needs a place visible without one,
   such as the menu.
6. **Show controls only where relevant.** The close button is shown only on the active tab,
   not on inactive ones, not even on hover.
7. **Editors imitate what they edit.** A setting about something visible is edited on a
   likeness of it (its real layout and style), not on an abstract list.
8. **Width is a resource.** No counters or extra text that would widen a narrow column (no
   "12/16" in the anchor header).
9. **A refused action says why.** When an action can't be done (e.g. the anchor limit), the
   control shows a "not possible" mark on hover instead of its usual one (a crossed circle).
   Trying anyway shows a short notice (rule 19) next to the element, sliding out from left to
   right: a few words read at a glance ("16 anchors at most").
9a. **Hints don't explain the obvious.** A placeholder or hint names what the control is for
   ("Search in payload") and nothing more: no keys that do the expected thing (Enter runs,
   → moves on), no instructions for basic editing. Behaviour should be self-evident.

## Shapes and Drawing

10. **No overflow scrollbars.** Elements shrink to fit their container instead of causing a
    horizontal scrollbar; long text is cut in the middle, the full text available on hover
    (only the overflow tooltip, no `title` tooltip on tabs). Exception: the log table (rule 26).
11. **Content decides the size, no artificial caps.** A tab is as wide as its full name, with
    no maximum width (unlike Chrome's equal tabs); it is cut only when the strip has no room.
12. **Precise drawing.** Elements with the same role have the same geometry (the tab separator
    has exactly the width of the drop marker). An overlay covers what it replaces
    completely: no pixel may peek out. Controls are centred where they sit.
13. **Smooth, rounded shapes.** Rounded corners (the radii: `docs/ui-guidelines.md`), subtle hover backgrounds,
    thin low-contrast separators hidden next to the active/hovered item.
14. **Popups continue their owner.** A tooltip over an element looks like its continuation: a
    bit lower than the owner and rounded the same way.
15. **Animate appearing marks.** A mark that appears or disappears (the anchor) grows from its
    centre while becoming opaque and collapses back on removal. Simple, CSS first.
16. **Lists show what a click will pick.** An open dropdown list (and any list of choices)
    highlights the item under the mouse, only that item while the mouse is over the list, with
    the accent of the menu items.

## Direct Manipulation

17. **Z-order.** The dragged object is on top; helper indicators (drop marker) are under it.
18. **Feedback for drag and drop.** While dragging, the other items make room with animation
    and a marker shows where the item will land. Tooltips are hidden during a drag, including
    any already shown when it starts.

## Feedback and States

19. **Notices disappear by themselves.** An informational notice ("copied N of M rows") is a
    non-modal popup near the element it is about that hides itself after a few seconds; a
    modal message box only when a popup isn't feasible.
20. **Comfort margins yield to small panels.** A margin kept for context (rows above a row
    scrolled to) is given only while the panel has room; in a low panel the target itself
    must stay visible.
21. **Status views are uniform and fit any panel.** Failure / cancel / lost-file / waiting
    views share one layout (`.status-view`: title, detail line, buttons), centered by
    flexible margins so a low panel never pushes content out of view. They have no progress:
    an operation running shows its progress under the table (21a). Errors from the core are
    shown; after a cancel or failure the detail says what to do next.
21a. **Tables show rows before an operation ends.** A file being loaded shows the records
    found so far (those its filters let through), with no progress and no Cancel by the table:
    its tab shows the progress, closing the tab stops the load. A filter or a search shows
    what it found so far, with its progress and Cancel in a strip under the table
    (`.view-progress`), no row covered; before the first row is found too, the table empty:
    the progress of a filter or a search is always under the table, never over it (a file
    whose anchors or matches come at once and one where they don't look the same). After
    a cancel or a failure: the status view.
22. **Empty states are useful and calm.** Centered; an accented title, a one-line hint with the
    shortcut, then something actionable (recent files that open on click); no decorative
    emoji, muted secondary text via theme variables.
23. **Prominent in the empty state, compact at work.** A control needed first is labelled while
    there's nothing else and shrinks to its compact form in place once work starts, animated;
    the compact form gets a tooltip instead of the label.

## Tabs and the Menu

24. **"+" opens a New Tab, not a dialog.** With files open, "+" opens a "New Tab" (last in the
    strip, one at most; "+" again shows it) with the start screen: title "Open a file", recent
    files, and the hint "Open a DLT log with ⌘O" whose first word "Open" is a link-like button
    opening the dialog. A file opened from it takes its place; ⌘O / File → Open open the
    dialog directly. Without files the start screen stays tabless and without "+"; the New Tab
    isn't saved between sessions.
25. **One menu, each platform's conventions.** The menu is described once in D (`ui/app_menu`);
    macOS gets it native, Windows/Linux as a menu bar the script draws from its JSON model.
    Layouts follow the platform: Windows File → Exit Alt+F4, Linux Quit Ctrl+Q, mnemonics with
    `&` on Windows/Linux only. Shortcut texts in hints come from the same model (⌘O / Ctrl+O).
    D gives the model, the script renders: D builds no Sciter markup.
45. **After a tab is switched, the keys go to its document.** A click on a tab leaves the
    keyboard in that document's panel (its table, or what had the focus there) once the button
    is released, as opening a file does; never nowhere. A switch shows the panel at once, the
    focus follows the release: it must not slow the switch down (`press-focus.js`).

## Log Table

26. **Payload readable, auxiliary columns single-line.** Payload is always shown whole and
    wraps. The auxiliary columns (index, times, ids, type, level) are on one line, never cut,
    no ellipsis; their widths are minimums so the layout is recalculated rarely. An exception
    to rule 10. The font size setting scales the font only. Settings → Table → "Single-line
    rows" (off by default) makes every row one line high, Payload not wrapped and not cut: it
    runs on to the right and the table scrolls sideways (chosen over an ellipsis).
27. **Rule colors mark, they don't paint.** A record matching a filter rule with a color is not
    painted whole: only its Index cell shows the color, a gradient from the left edge fading
    out at about a third of the cell; the row's own background (stripes, selection) stays.
    The white and grey stripes are the look of every row in both tables: a row the search
    found keeps them, and the text of a found row keeps its contrast (no layer over it). For
    now a found row has no mark of its own, only its matches in the colors of their chips; a
    mark is being chosen (`docs/backlog.md`).
28. **The other table follows the selected row.** A row selected in the main or the search
    table is shown in the other one if it has that message: selected there, scrolled only if
    not already on screen (near the top then; the far part of the way is jumped over, the last
    half screen or so scrolls animated, so the eye sees which way the rows went; Go to Message
    scrolls the same way). Multiple
    selection: the last
    clicked/dragged-to/arrowed row. A click follows at once; a drag and the arrow keys only
    after the row rests 500 ms. The keyboard focus stays in the table where the user selects.
29. **Text is selected across cells and rows.** A plain drag in any cell (not the anchor)
    selects text from the press to the mouse, across cells and rows, auto-scrolling at the
    edges; a plain click selects the row; Shift/Cmd click and drag work on rows. A double click
    selects a word, a triple click the whole text of its cell; Escape clears the text first,
    then the rows; Cmd+C copies the selected text if any, else the rows (cells by tabs, rows by
    new lines); the row context menu offers "Copy" while text is selected, and "Copy Row".
    Selected text is painted over the match colors (`--bg-text-selected`).
30. **A file being written grows, the table at its end follows it.** Every open file is
    followed (no switch): the lines written to it come into the table by themselves. A table
    whose last row is wholly on screen, with no current row or the last one current, follows
    the end as `tail -f` does, the current row staying the last (rows chosen up to the last
    stay chosen: only a single current row moves with the end); a table scrolled up, or with
    a row above the last chosen, stays where it is. The other table doesn't follow these
    moves. Only rows of a file being written are
    followed: a table a load, a filter or a search fills stays at its top. A line cut by the
    end of the file is shown once the file is quiet for a second; a file emptied by a
    rotation is opened anew in its tab.

## Search

31. **Queries apply only on explicit commit.** Editing a query and its modes (text, Regex,
    Ignore case) doesn't change the results; only Enter or the Search button commits it. While
    the controls differ from the committed query, the panel shows it (tinted toolbar
    `--bg-search-pending`, the Search button becomes primary). The draft (with its error) and
    the committed query belong to the document: each tab shows its own.
32. **Match colors: one shared set of pale colors.** 16 pale colors on which the theme's text
    reads well (light: pastels under dark text; dark: muted tones of the same hues under light
    text), called "match colors", kept as constants (`--match-color-0…15` in both themes,
    classes `match-color-N` in `resources/match-colors.css`, `matchColorCount` in
    `match-colors.js`; a test checks all three agree). Search chips and their matches use them.
    Regex chips are in a monospace font.

## Filters

33. **The filters panel replaces a quick filter.** No per-column quick filter. Filter files are
    only appended (no "replace" load); each loaded filter has a delete (×) button. A whole
    filter and each of its rules can be switched on and off. Loaded filters are copied into the
    settings of the log, not referenced by path: a `.dlf` shared by two logs must not tie them
    together. The design allows filters for every format.
34. **The filter editor is a modal window.** A rule is edited in a modal window (like Settings),
    not inline in the panel. Edits apply and are remembered at once (no
    Save, no unsaved prompts); a set can be exported to a `.dlf`. "New
    Filter" creates an empty set without asking for a file and opens the editor of its first
    rule. The DLT rule editor offers exactly the conditions a `.dlf` can hold.

## Recent Files

35. **Immediate and forgiving.** A file joins the recent list (newest first, max 8) as soon as
    it opens, and the list is saved at once. A file that no longer exists stays listed, grayed,
    with a "File not found" note; a file that failed to open goes on top, marked "Failed to
    open" with the reason under it (error color), and the New Tab is brought up if a document
    was shown; the reason disappears after a successful open or "+".
36. **A file remembers its format.** A recent file opens in the format it was opened with last
    time, not by detection; with no saved format it is detected and then remembered. The
    format is shown left of the name as a badge; all badges look uniform (three-letter
    abbreviations of the same shape).
37. **Recent files tell when they were used.** Right of the name: "Opened" for an open file
    (clicking it switches to its tab), otherwise when it was worked with last: "Just now",
    "N minutes/hours ago" within 24 h, "Yesterday, 14:05", "2 days ago, 14:05",
    "3 Nov, 14:05", the year only if not this one. Notes go on a line under the path. No live
    refresh while the screen is shown.
38. **Actions in a per-row menu.** Hovering a recent file shows a "⋮" button at the right of
    its row, in a slot of its own (nothing moves); it stays while its menu is open. The menu
    acts on that file only: Show in Folder, Copy Path, then apart Remove from Recent. The
    labels are the same on every system. An open file has no Remove; a file not found has Show
    in Folder disabled. No "Clear all recent". Remove has no confirmation and no undo for now.

## Settings

39. **Settings has sections.** The dialog lists its sections on the left like vertical tabs
    (Appearance: language, theme; Table: the font size first, then the columns); one
    Save/Cancel for all. The font size applies at once to the column strip, which is the
    preview; the size the dialog opened with is shown in italics in the list. At a large font
    the checkboxes keep their size; the strip may grow wider than the dialog and scroll.
40. **Table columns are arranged per format.** For each format (by its id, all variants
    together) the user orders the columns and hides some; the layout is global for every log
    of that format. Index stays first and Payload last. Columns are reordered by dragging with
    the feedback of rule 18. The editor shows the columns as they look: a strip of headers
    styled exactly like the table header, the visibility checkbox under each; a hidden
    column's header is faded.
41. **Settings start from the current document.** A per-format setting opens on the format of
    the active tab and marks it in the list ("DLT (current file)").

## Bottom Panel

42. **Tabs below the pages.** The panel under the main table is a set of pages with a tab strip
    at its bottom (IDE-like; the active tab merges with its page above). No title header inside
    a page when its tab already names it. The strip under the tabs stays grey (`--bg-header`).
    Each page has its own color, so the page open is seen at a glance: Search that of its results table (`--bg-table`),
    Filters mint, File Info blue, MCP Server lavender (`--page-<page>-bg`; pale in the light
    theme, dark tints in the dark one). A page and its active tab share that color; inactive
    tabs stay on the grey of the strip.
    Tabs of the current document (data source) are on the left, in this order: "Search",
    "Filters", "File Info"; tabs of the whole application are on the right: "MCP Server".
    The "Filters" tab has a dot after its name while some rule works on the log (an enabled,
    applied rule of an enabled set, markers too), so a filtered log is seen with another page
    open; the dot grows in and out, the tab keeps its width.
43. **File Info.** Path, Size (physical size with the record count next to it), Format, and
    for a DLT log FIBEX last: the path of the FIBEX with "file" or "folder" after it (or that
    there is none; the remembered one muted while it is read or if it can't be), a note under
    it (reading, or why it can't be read: the one before stays), and the buttons Load File,
    Load Folder (the system dialogs pick files or folders, not both) and Unload. No Name row
    (the tab shows it). Every value that carries information is selectable.
44. **Filters as chips.** The Filters page shows a block per filter set: its head (switch,
    name, buttons) on its own line, its rules as chips wrapping under it, indented (switch,
    color with the kind in it (+, −, ◆), name). Remove and edit of a rule (× leftmost, then ✎)
    are in a tab that slides out of the left of its chip on hover (200 ms), its continuation:
    its height, its hover color and border, no right border, the chip's left border wiped out
    once it is out; out of the chip's width, the chips indented enough for it. A rule not applied has a red border,
    and a red line under its set's chips says why (rule name: error). New Filter and Load Filter
    are in the page's toolbar. In a narrow window the chips shrink to the row, a long name
    cut; a switch toggled keeps the focus.
