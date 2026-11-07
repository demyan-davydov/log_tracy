# Building DLT Explorer

DLT Explorer builds with one command on macOS, Linux and Windows: `scripts/build.mjs`. dub does
the building; the script adds the tests, the distributions and a compile check for Windows.

## Setting up

You need:

- **LDC** (`ldc2`), the LLVM-based D compiler. dmd is not supported: the project builds with
  ldc2 only. It is developed with LDC 1.43.
- **dub**, the D build tool.
- **Node.js** 22 or newer: the build script, the JS tests, the translation tools.
- **Git LFS**: the Sciter libraries in `libs/` are kept in it.
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

Not tried yet: tell what had to be done differently.

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

Not tried yet: tell what had to be done differently.

1. [Visual Studio Build Tools](https://visualstudio.microsoft.com/downloads/) with the
   "Desktop development with C++" workload: the linker, the Windows SDK and the resource
   compiler for the icon (`resources/app.rc`).
2. LDC: the installer `ldc2-<version>-windows-multilib.exe` from the
   [LDC releases](https://github.com/ldc-developers/ldc/releases). It brings dub too.
3. [Git for Windows](https://git-scm.com/download/win), which includes Git LFS.
4. Node.js 22 or newer from [nodejs.org](https://nodejs.org).

Run the commands below from a terminal that sees all of them (`ldc2 --version`,
`dub --version`, `node --version`).

### Getting the sources

```sh
git clone <repository>
cd dlt_explorer
git lfs install    # once per machine
git lfs pull       # the Sciter libraries; without it libs/ holds pointers, not libraries
```

If you installed Git LFS after cloning, `git lfs pull` fetches what is missing.

## Commands

The commands can be run from any folder: the script goes to the project root itself.

```sh
node scripts/build.mjs                    # debug build for this machine
node scripts/build.mjs --release          # release build
node scripts/build.mjs --arch x64         # another architecture: x64 or arm64
node scripts/build.mjs test               # the D unittests and the JS tests
node scripts/build.mjs dist               # a distribution
node scripts/build.mjs check-windows      # compiles for Windows x64 from macOS or Linux
```

### Where the build goes

Every build has its own folder, `build/<platform>-<architecture>-<type>/`: for example
`build/osx-aarch64-debug/`, `build/linux-x86_64-release/`, `build/windows-x86_64-unittest/`
(the tests). dub puts the Sciter library of `libs/` next to the program, so it runs from
there as it is. Plain `dub build --compiler=ldc2` and `dub test --compiler=ldc2` do the same.

The program keeps its settings (`settings.json`) next to itself, so every build has its own.

The files of the interface (`resources/`) are built into the program: a change of HTML, CSS or
JS needs a rebuild.

### Tests

`test` runs the D unittests (`dub test`) and the JS tests (`node --test tests/js`), the second
even when the first fail, and tells the result of both. The JS tests also check that the
translation catalogs are up to date with the code (`node scripts/i18n-extract.mjs` updates
them).

### Distribution

`dist` makes a release build and puts a distribution in
`build/dist/<macos|linux|windows>/`. The previous one is replaced only once the new one is
complete. The version comes from the `VERSION` file.

- **macOS**: `DltExplorer.app`, signed ad-hoc, and `sign.command` next to it. macOS won't start
  a downloaded program: it is quarantined, and an ad-hoc signature holds only on the machine
  that made it. `sign.command` (opens from Finder) clears the quarantine and signs the program
  again. For now it is built for the architecture of the machine only; a universal program is
  in `docs/backlog.md`.
- **Linux**: the program, `libsciter.so`, the icon and `dlt_explorer.desktop`. To install,
  copy the folder to `/opt/dlt_explorer` and link the `.desktop` file into
  `~/.local/share/applications`.
- **Windows**: `dlt_explorer.exe` and `sciter.dll`; the icon is built into the program.

### Checking Windows from macOS or Linux

A Windows program can only be linked on Windows. From macOS or Linux, `check-windows`
compiles the program and its unittests for Windows x64 without linking: enough to catch code
that doesn't compile on Windows.

## The Sciter libraries

`libs/<system>/[<architecture>/]` holds the Sciter libraries of every platform; their version
is in `libs/VERSION`. To update Sciter, replace the files and `libs/VERSION` in one commit: the
binding (`source/sciter/capi`) is written for the API of that version.
