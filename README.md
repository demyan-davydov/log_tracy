# DLT Explorer

A desktop viewer for DLT and text logs on macOS, Linux and Windows, written in D with the
[Sciter](https://sciter.com) UI framework. A functional counterpart of dlt-viewer with a more
convenient interface. Logs of about a gigabyte open without loading them into memory: the
file is mapped, and its indexes are built on background threads with the progress shown, the
window staying responsive.

## What It Does

- Opens binary DLT (protocol versions 1 and 2) and text logs: Android logcat, kernel log
  (dmesg), syslog, web server access logs, CAN traces (candump, Vector ASC), plain text. The
  format is detected by the content; see [docs/formats.md](docs/formats.md).
- Filters by rules on any column, as in dlt-viewer, including `.dlf` filter files of
  dlt-viewer; colors the rows the rules mark.
- Searches by text and regular expressions, several queries at once, each in its own color.
- A tab per open log, each with its own filters, search and selection; recent files remember
  their format and filters.
- Table columns arranged per format, light and dark themes, translations.

## Building

```sh
git lfs pull                      # the Sciter libraries of libs/
node scripts/build.mjs            # debug build for this machine
node scripts/run.mjs              # build and start
node scripts/build.mjs test       # D and JS unit tests
```

Setting up the tools on each system and the other commands: [docs/building.md](docs/building.md).

## Documentation

- [docs/building.md](docs/building.md): building, testing, distributions.
- [docs/formats.md](docs/formats.md): the formats supported and planned.
- [docs/ui-guidelines.md](docs/ui-guidelines.md): visual standards of the interface.
- [docs/performance.md](docs/performance.md): measurements of indexing and table rendering.
- [docs/stories/](docs/stories/): the story of each feature, what was decided and why
  (Russian).
- [docs/experiments/](docs/experiments/): experiments and measurements decisions rest on, such
  as ways of working compared (Russian).
- [docs/backlog.md](docs/backlog.md): what was noticed and left for later (Russian).

## Repository Context

[`.ai/`](.ai/INDEX.md) holds the shared context of the repository, written for developers and
agents alike: how the code is built and where to start a change (`knowledge/`), the rules
every change and review follows (`rules/`), and recurring processes (`workflows/`). Agents
reach it through [AGENTS.md](AGENTS.md); [CLAUDE.md](CLAUDE.md) only imports it for Claude Code.
