# Building Log Tracy

Log Tracy builds with one command on macOS, Linux and Windows: `scripts/build.mjs`. dub does
the building; the script adds the tests, the distributions and a compile check for Windows.

## Setting up

Node.js 22 or newer is the one thing to install by hand: the script that sets up the rest
runs on it. `node scripts/install-deps.mjs` checks the tools below and tells what is
missing and the command that installs it; `node scripts/install-deps.mjs --install` runs
that command (the package manager of the system: Homebrew, apt, dnf, pacman or winget; on
Linux through `sudo`) and checks again. What it can't install (Node.js, LDC on Windows, a
system without a package manager it knows) it lists as done by hand. `--dev` adds the tools
of development that a build doesn't need (screenshots and stacks on Linux). The exit code is 1
while something is missing. The steps below are what the script does, for doing it by hand.

You need:

- **LDC** (`ldc2`), the LLVM-based D compiler. dmd is not supported: the project builds with
  ldc2 only. It is developed with LDC 1.43.
- **dub**, the D build tool.
- **Node.js** 22 or newer: the build script, the JS tests, the translation tools.
- **Git LFS**: the Sciter libraries in `libs/` are kept in it, packed.
- A C toolchain for linking (below, per system).

### macOS

1. The command line tools of Xcode (the linker):

   ```sh
   xcode-select --install
   ```

2. The rest from [Homebrew](https://brew.sh):

   ```sh
   brew install ldc dub node git-lfs
   ```

   Homebrew's LDC builds for the architecture of the machine only (its runtime is arm64 on
   Apple silicon), which is all the build needs now.

### Linux

Checked by the CI on Ubuntu, x64 (`ubuntu-latest`) and arm64 (`ubuntu-24.04-arm`), not yet by hand: tell what had to be done
differently.

1. A C toolchain and GTK 3, which Sciter draws with. On Debian or Ubuntu:

   ```sh
   sudo apt install build-essential libgtk-3-dev git git-lfs
   ```

2. LDC and dub. The packages of the distribution (`apt install ldc dub`) are often old; the
   official install script puts a current LDC with its dub in `~/dlang`:

   ```sh
   curl -fsS https://dlang.org/install.sh | bash -s ldc
   source ~/dlang/ldc-*/activate     # in every new shell, or add it to ~/.bashrc
   ```

3. Node.js 22 or newer, from [nodejs.org](https://nodejs.org) or your package manager
   (check `node --version`: distributions often ship an older one).

### Windows

Checked by the CI on Windows Server (`windows-latest`, Visual Studio and LDC 1.43), not yet by
hand: tell what had to be done differently.

1. [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/) with the
   "Desktop development with C++" workload: the linker, the Windows SDK and the resource
   compiler for the icon: before every build dub runs `scripts/windows-res.mjs`, which
   compiles `resources/app.rc` into `build/windows/app.res` with `rc.exe` (the one on the
   PATH, else that of the newest Windows SDK).
2. LDC: the installer `ldc2-<version>-windows-multilib.exe` from the
   [LDC releases](https://github.com/ldc-developers/ldc/releases). It brings dub too.
3. [Git for Windows](https://git-scm.com/download/win), which includes Git LFS.
4. Node.js 22 or newer from [nodejs.org](https://nodejs.org).

Run the commands below from a terminal that sees all of them (`ldc2 --version`,
`dub --version`, `node --version`).

### Getting the sources

```sh
git clone <repository>
cd <the folder of the clone>
git lfs install    # once per machine
```

The Sciter libraries of `libs/` are kept packed by brotli, a quarter of their size: five
archives, one per system and architecture (`libsciter.dylib.br`, `sciter.dll.br`, ...), 5 to
13 MB each. A clone fetches none of them (`.lfsconfig`). The first build fetches the one it
needs (`node scripts/build.mjs` runs `git lfs pull --include=<archive> --exclude=`) and unpacks
it next to itself, the others stay pointers. The unpacked library is ignored by git; a build
unpacks it again when the archive changes (a checkout, an update of Sciter). A plain
`dub build` doesn't fetch nor unpack it: run a build of the script once first.

## Commands

`scripts/` holds what builds, runs and tests the program: `build.mjs`, `run.mjs`, `test.mjs`
(`node scripts/build.mjs test` under a name that says so) and two helpers of the build.
The tools of development are in `scripts/utils/`: screenshots, driving the app, the stacks of
a hung app, benchmarks, the test log generator, the translation catalogs, the icons, the
review lenses, the check of `.ai/`.

The commands can be run from any folder: the script goes to the project root itself.

```sh
node scripts/build.mjs                    # debug build for this machine
node scripts/build.mjs --release          # release build
node scripts/build.mjs --debug-channel    # with the debug channel (also with --release), see below
node scripts/build.mjs --arch x64         # another architecture: x64 or arm64
node scripts/test.mjs                     # the D unittests, the JS tests, the names of .ai/
node scripts/test.mjs --module <file.d>   # the unittests of one D module (see "Tests")
node scripts/build.mjs dist               # a distribution
node scripts/build.mjs gen-log <file> ... # a test log (see "A test log" below)
node scripts/build.mjs bench [log] ...    # this tree against master (see "Measuring" below)
node scripts/build.mjs pack-libs          # the Sciter libraries into their archives (see below)
node scripts/test.mjs --brief             # only what failed (any command but gen-log and bench)
node scripts/build.mjs --help             # the commands and options
```

`node scripts/run.mjs` builds as `build.mjs` does, with the same `--release` and `--arch`, and
starts the program from its build folder; its output goes to the same terminal.

### Where the build goes

Every build has its own folder, `build/<platform>-<architecture>-<type>/`: for example
`build/osx-aarch64-debug/`, `build/linux-x86_64-release/`, `build/windows-x86_64-unittest/`
(the tests). dub puts the Sciter library of `libs/` next to the program, so it runs from
there as it is. Plain `dub build --compiler=ldc2` and `dub test --compiler=ldc2` do the same
once a build of the script has unpacked the library; they don't fetch nor unpack it themselves,
so after a checkout that changes the archive build with the script first.

The program keeps its settings (`settings.json`) next to itself, so every build has its own.
Only a distribution keeps them in the user's folder (see "Distribution" below).

The files of the interface (`resources/`) are built into the program: a change of HTML, CSS or
JS needs a rebuild.

### Tests

`node scripts/test.mjs` (the same as `node scripts/build.mjs test`) runs the D unittests (`dub test`) and the JS tests (`node --test "tests/js/*.test.mjs"`), the second
even when the first fail, and tells the result of both.

`dub test` builds the configuration `unittest` of `dub.sdl`: the runner of
[unit-threaded](https://github.com/atilaneves/unit-threaded), whose `main` its `gen_ut_main`
generates into `build/unittest/ut.d` before every build. It runs in one thread
(`unitUnthreaded`), so tests that share a global state are safe. Every `unittest` block is a
test of its own, named by its `@("...")` string: a failed one doesn't stop the ones after it,
and the report lists every failed test by name. `test --filter <name>` runs only the D
unittests whose names start with `<name>` (a module such as `utils.fsm`, or a test's full
name; the option may be repeated), without the JS tests; it is `dub test --compiler=ldc2 --
<name>`. The runner's own options: `dub test --compiler=ldc2 -- -h` (`-l` lists the tests). The JS tests also check that the
translation catalogs are up to date with the code (`node scripts/utils/i18n-extract.mjs` updates
them). Last, `scripts/utils/check-ai-context.mjs` looks up what `.ai/`, `AGENTS.md`, `CLAUDE.md` and
`.claude/` name in backquotes (paths, identifiers, options) and lists those the code no longer
has; a name that is right though the code lacks it goes to the `allowed` list of the script.

`test --module <file.d>` builds the unittests of one D module and of the modules it imports
with `ldc2` alone (the flags of `dub.sdl`, as `dub describe` gives them), into `build/tools/`:
a quick check of a module that doesn't depend on Sciter. It runs druntime's test runner, not
unit-threaded's: no filter, and a module is left at its first failing `unittest`, the ones after
it did not run.

### Brief output

`--brief` (with `build`, `test`, `test --filter`, `test --module`, `dist`, and `run.mjs`)
writes the whole output of every step to `build/brief.log`, rewritten on each run, and
shows only what failed: the compile and link errors, the failed D unittests (the place, the
exception, its message, the frames in the project's code), the failed JS tests (the place,
the name, the diff) and the summary of each runner. When all goes well, only the last line
is left, such as `D unittests: OK, JS tests: OK, context of .ai/: OK`. A failed step whose
lines don't tell the cause (a crash, a linker message not known) shows its last lines too, so
a failure never goes silent. It is meant for
AI agents, whose context the whole output would fill, and for a quick look; the filter is
`scripts/build-output-filter.mjs`.

### Distribution

`dist` makes a release build of an installed program (dub's build type `dist`, in
`build/<platform>-<arch>-dist/`) and puts a distribution in
`build/dist/<macos|linux|windows>/`. The previous one is replaced only once the new one is
complete. The version comes from the `VERSION` file.

An installed program can't write next to itself, so a distribution keeps its settings in the
user's folder, created on the first start:

- **macOS**: `~/Library/Application Support/Log Tracy/`
- **Linux**: `$XDG_CONFIG_HOME/log_tracy/`, by default `~/.config/log_tracy/`
- **Windows**: `%APPDATA%\Log Tracy\`

Every other build (debug, `--release`) keeps them next to itself, as above.

- **macOS**: `LogTracy.app`, signed ad-hoc, and `sign.command` next to it, and the same two
  in a disk image, `LogTracy-<version>-macos-<arch>.dmg`, next to a link to Applications to drag the
  program onto. macOS won't start a downloaded program: it is quarantined, and an ad-hoc
  signature holds only on the machine that made it. `sign.command` (opens from Finder) clears
  the quarantine and signs the program again: the one next to it, or, opened from the disk
  image, the one already dragged into Applications. The disk image doesn't change that: only a
  Developer ID signature and notarization would. For now it is built for the architecture of the machine only; a universal program is
  in `docs/backlog.md`.
- **Linux**: the program, `libsciter.so`, the icon and `log_tracy.desktop`, and the package
  `LogTracy-<version>-linux-<x64|arm64>.deb`, made where `dpkg-deb` is (Debian, Ubuntu, the CI).
  To install, `sudo apt install ./LogTracy-<version>-linux-x64.deb`: the program goes to
  `/opt/log_tracy`, the desktop entry to `/usr/share/applications`, GTK 3 comes as a
  dependency. Without the package, copy the folder to `/opt/log_tracy` and link the
  `.desktop` file into `~/.local/share/applications`.
- **Windows**: `log_tracy.exe` and `sciter.dll`, the icon built into the program, and the
  same two in `LogTracy-<version>-windows-<arch>.zip`, in a `LogTracy` folder: no installer,
  it runs where it is unpacked. The program is unsigned: Windows SmartScreen warns about it
  on the first start ("More info", then "Run anyway").

The icons of the three systems are made of the logo, `resources/app-icons/logo.png` (a square of
1024 px), by `node scripts/utils/make-icons.mjs` on macOS (`sips`, `iconutil`): `app.icns` for the
bundle, `app.ico` for Windows (16 to 256 px), `app.png` for Linux and `png/icon-<size>.png`
of every size from 16 to 1024. Run it after the logo changes and commit what it writes.

### A release

A tag of the version publishes a release on GitHub. Bump `VERSION`, commit, then:

```sh
git tag v0.9.0
git push origin v0.9.0
```

The CI builds and tests the three systems as for any push and, once they pass, its `release`
job publishes the release `v<version>` with the `.dmg`, the two `.deb` (x64 and arm64) and the Windows `.zip`,
and the notes of the commits since the last one. It stops if the tag is not the version of
`VERSION`. The README links to the latest release.

### A screenshot of the window

`node scripts/utils/screenshot.mjs --open <log>` builds the program, starts a copy of it in a
temporary folder (with settings of its own: the build's `settings.json` stays as it is), opens
the log, waits for it to load and captures the window of the program only, into
`build/screenshot.png`. `--help` lists the options: several logs, the wait, a `settings.json`
to start with (theme, language), environment variables for the program (see
[Environment variables for development](#environment-variables-for-development)).

- **macOS**: the first run compiles a small helper with `swiftc` (the Xcode command line
  tools); the terminal needs the Screen Recording permission.
- **Windows**: PowerShell, nothing to install.
- **Linux**: X11, with `xdotool` and ImageMagick (`import`) installed. In a Wayland session the
  program is started on XWayland (`GDK_BACKEND=x11`); Wayland alone, without XWayland, lets no
  program capture another's window.

Windows and Linux were not tried on those systems yet.

### Driving the app: the debug channel

`node scripts/utils/app.mjs` drives a running copy of the app through its debug channel (`SCITER_DEBUG_PORT`): it looks inside the window instead of
guessing from a screenshot. The channel is in a build only when asked, a debug build too:
`node scripts/build.mjs [--release] --debug-channel` (D version `DebugChannel`); `app.mjs start`
builds it itself, and `start --release` drives a release, for what only a release shows.

```sh
node scripts/utils/app.mjs start --open ~/logs/trace.dlt     # builds, starts a copy in build/app, keeps it running
node scripts/utils/app.mjs wait "document.$('.log-table-view') != null" --timeout 15  # the table of the log is there, its rows may still load
node scripts/utils/app.mjs eval "document.$('.log-table-view')" # {tag, class, text, box} of the element
node scripts/utils/app.mjs shot build/x.png                   # the window rendered by Sciter
node scripts/utils/app.mjs hover ".btn-chip-history"          # the mouse over an element (or "x y"), macOS
node scripts/utils/app.mjs key "Cmd+A"                        # a key in the focused element, macOS
node scripts/utils/app.mjs type "error 42"                    # a text, a key a character, macOS
node scripts/utils/app.mjs run steps.txt                      # eval/wait/shot/hover/key/type steps, one a line
node scripts/utils/app.mjs stop
```

The copy has its own settings (`--settings` to start with a `settings.json`) and its output in
`build/app/app.log` (`app.mjs log`). The code runs in the global scope of the window: what the
modules put on `globalThis`, `document`, `Window.this` (`$` of the modules is not global:
`document.$(...)`). `shot` needs no permission of the system: Sciter renders the window
itself, without the title bar of the system. An open popup (a menu, a tooltip, the list of a
`<select>`) is a window of its own: `shot` writes its image beside, `x.popup-1.png` and on, and
tells its file and element (`{tag, id, class, text, box}`, `box` in the window); one that
closed by itself before its image (a tooltip, a notice) is told as `closed`; the popup files
of an earlier shot into the same path are removed. `hover`,
`key` and `type` (macOS only) hand the window events of the system, as if the user moved the
mouse or typed: `:hover`, `mouseenter`, `keydown`, text typed follow; the cursor stays where it
is; over an open popup the move goes to the popup. "Cmd+A" is Cmd and a (Shift is written),
a text starting with `--` goes after `--` (`type -- "--x"`). A press of a mouse button can't
be handed so (`el.click()` in `eval`), Sciter's own
tooltip of `title` doesn't show, and a shortcut of the menu bar doesn't reach the menu.
`--help` lists the rest. The channel is a line of
JSON per request on a TCP connection (`source/ui/debug_protocol.d`).

### A test log

The real logs are not in the repository. `gen-log` writes one of a format, size and content,
the same file byte for byte for the same options and seed on every machine:

```sh
node scripts/build.mjs gen-log build/big.dlt --format dlt --size 1G
node scripts/build.mjs gen-log build/v2.dlt --format dlt-v2 --count 100000 --non-verbose 10% --corrupt 0.1%
node scripts/build.mjs gen-log build/text.log --format text --count 50000 --cyrillic 30% --invalid-utf8 1%
node scripts/build.mjs gen-log --help
```

The formats are `dlt` (protocol and storage header of version 1), `dlt-v2` and `text` (plain
text); the other text formats come later. The options set how many ECUs, apps and contexts there are,
the weights of the levels, the length of the texts, the shares of multiline texts, Cyrillic
words, bytes that are not UTF-8 and non-verbose messages, and records broken on purpose: junk
between records, a broken header or length, a time going back, a line too long for a record,
a cut last record. The generator (`source/formats/generator/`) is built into
`build/tools/gen_log` by every run, optimized: about 13.5 seconds for a gigabyte of DLT on an M1 Pro.
It is not in the program: its modules are compiled only for the unittests and with
`-d-version=LogGenerator`.

### Measuring

`bench` measures this working tree against `master` (`--against` another ref) with
`scripts/utils/bench_rows.d` (scrolling, the default) or `--bench index` (`scripts/utils/bench_index.d`,
building the indexes). It checks the ref out into a temporary worktree, puts this tree's
benchmark into it, builds both sides alike, reads the log once into the page cache, runs the
sides by turns, each going first in every other run (`--runs`, 3), and prints the median and
the spread of every number of both sides and their difference (`~ noise` when the spreads
overlap);
`--json <file>` keeps every run. Without a log it takes one the generator writes once
(`build/tools/bench-dlt-256M-seed1.dlt`). How to read the numbers: `docs/performance.md`.

```sh
node scripts/build.mjs bench big.dlt failed value
node scripts/build.mjs bench --bench index big.dlt error -- --rounds=5
node scripts/build.mjs bench --help
```

### The stacks of a hung app

`node scripts/utils/backtrace.mjs [pid]` writes the stacks of every thread of a running Log
Tracy into `build/backtrace-<pid>.txt` (`--out` another file) with `lldb` on macOS or `gdb`
on Linux, and leaves the process running. Without a pid it takes the copy of
`scripts/utils/app.mjs`, else the only running `log_tracy`.

## Environment variables for development

The program reads a few environment variables, for trying and checking things during
development; users don't need them. They are read at start, in `newSession` of
`source/app.d`; `SCITER_DEBUG_PORT` in `source/ui/debug_channel.d`.

| Variable | Values | What it does |
|---|---|---|
| `OPEN_AT_START` | `<log>`, several on lines of their own | Opens these logs at start, each in its tab. `scripts/utils/screenshot.mjs` uses it. |
| `UI_PLATFORM` | `windows`, `linux` | Draws the interface of that system, also on macOS: its menu (Exit Alt+F4 or Quit Ctrl+Q) in the window and the styles of `@media ui-platform == ...`. Only the interface: the OS stays what it is (Cmd or Ctrl, the native menu of macOS, the dialogs). |
| `PSEUDO_LOCALE` | `1` | Offers the pseudo translation in Settings: every text accented and lengthened, so what stays plain English is not translated. |
| `SCITER_DEBUG_MODE` | `1` | Turns the debug mode of Sciter on, for its inspector: start `inspector.app` of the Sciter SDK first, then Ctrl+Shift+I in the window connects to it (the DOM, the styles, a script console), Ctrl+Shift+click shows the element clicked. |
| `SCITER_DEBUG_PORT` | `<port>`, `0` for any free one | Debug builds only: opens the debug channel on `127.0.0.1:<port>` (the port is written to the output), through which `scripts/utils/app.mjs` runs JavaScript in the window and renders it. A release build ignores it and says so. |

For example:

```sh
UI_PLATFORM=windows OPEN_AT_START=~/logs/trace.dlt build/osx-aarch64-debug/log_tracy
```

A new variable goes into this table.

## The Sciter libraries

`libs/<system>/[<architecture>/]` holds the Sciter libraries of every platform, each packed by
brotli into `<library>.br`; their version is in `libs/SCITER_VERSION`. To update Sciter, put
the new libraries in `libs/`, run `node scripts/build.mjs pack-libs` (a couple of minutes) and
commit the archives with `libs/SCITER_VERSION` in one commit: the binding (`source/sciter/capi`)
is written for the API of that version. The libraries themselves are ignored by git; until
they are packed, a build stops on a library that doesn't match its archive.
