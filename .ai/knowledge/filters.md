# Filters and Search

## Filters

- Filters implement `LogFilter!wchar` (`log_core/log_filter`). `matches` is called from many
  threads at once (the blocks of `utils/parallel_scan` and the UI thread): a filter doesn't
  change once built.
- Regular expressions go through `utils/text_regex` only (`TextRegex`, `RegexSet`): it is the one
  module that imports the engine (`std.regex`), so the engine can be replaced there alone.
  `std.regex` keeps one matcher per thread (the last expression): two expressions tried by
  turns on each record rebuild it every time, under the GC lock, and the scan gets slower with
  more threads (`docs/experiments/2026-11-10-regex-matcher-cache.md`). `RegexSet` joins the
  regex chips of a search into one alternation, each with its case; the regex conditions of
  the rules are still tried by turns (`docs/backlog.md`).
- The filters of the main view are rules, the same for every format
  (`log_core/rule_filter`):
  - a `FilterRule` (include / exclude / marker) is a set of `Condition`s on **column ids** of
    the format; a condition on a column the log doesn't have makes the rule "not applied"
    (`ruleError`), it is kept, never dropped silently;
  - a `FilterSet` is what one filter file holds; `RuleFilter.compile` builds the view filter
    from the enabled rules of the enabled sets (shown: an include rule matches, or there is
    none, and no exclude rule does; markers don't filter);
  - a rule has a `RuleId` while its document is open (given by `DocumentFilters`, not saved);
    `RuleMatcher` finds the first rule *with a color* a record matches, of any kind: it
    colors the row. It runs for every row shown on the UI thread: keep matching
    cheap (the conditions of a rule are checked cheapest first, substrings by code units).
    A fallback idea if it gets slow is in `docs/backlog.md`.

## Filter Files

- Our own JSON format (`log_core/filter_file`, `<name>.<format id>.logfilter`, the format is
  also written inside) for any log; a `.dlf` (`formats/dlt/dlf`) for DLT logs
  only, converted to rules and back (`fromDlf`, `toDlf`), naming what is lost.
- `ui/filter_commands.DocumentFilters` holds the sets of a document and the panel commands. A
  set is a **copy**: a loaded file is copied into the settings of the log
  (`RecentFile.filters`, rules as in a filter file), edits are remembered at once, and a set
  can be exported. No file is referred to, so a file loaded for two logs doesn't tie them
  together.

- Cancel of a running filter puts the boxes of the panel back (`AppSession.cancelMainView`):
  `DocumentFilters.markApplied` remembers them when a load or a filter ends
  (`DocumentUi.show`), `restoreApplied` sets them again and filters anew. Rules
  are found by id, sets by index (`remove` drops its entry).

## Rule Editor and Colors

- The rule editor (`resources/rule-editor.htm`) has a row per column of the format
  (`backend.columns(docId)`: all the columns, not the layout); the mapping of conditions to
  rows is the Sciter-free `resources/rule-form.js`, tested by `tests/js`.
- A row carries the id of the first colored rule it matches; the script looks its color up in
  the rules of the panel (`resources/rule-colors.js`) and `table.css` shows it on the Index
  cell only, as a fade from the left edge.

## Search

- The search is a query of chips (`ui/search_chips`, `log_core/search_filter`; script side
  `resources/search-editor.js`, `search-query.js`, `search-editing.js`, `edit-history.js`).
  Each chip has a match color (`resources/match-colors.*`).
- `SearchFilter.matchRanges` gives what the chips found in the payload, `[[start, end, chip]]`
  in UTF-16 units; `AppSession.matchesOf` computes nothing for a row the search didn't find.
- `std.regex` supports lookaheads `(?=…)`, `(?!…)`.
- The search runs in parallel blocks like the filter (`utils/parallel_scan`); its results are
  the search index of the document.
