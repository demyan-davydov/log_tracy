// What --brief of scripts/build.mjs keeps of the output of a step (scripts/build-output-filter.mjs). The
// outputs are cut from real runs of dub, ldc2, druntime and node --test.
// Run: node --test tests/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { filterBuildOutput, filterLimit } from "../../scripts/build-output-filter.mjs";

const root = "/p/dlt";

test("a step that went well says nothing, even when its tests print errors of their own", () => {
    const passed = `> dub test --compiler=ldc2
    Starting Performing "unittest" build using ldc2 for aarch64, arm_hardfloat.
    Building log_tracy ~master: building configuration [log_tracy-test-library]
     Linking log_tracy-test-library
     Running build/osx-aarch64-unittest/log_tracy-test-library
Sciter library loaded: libsciter.dylib
Error parsing the state of the script: Key not found: width
Error opening file /refused.log: not a log of DLT or text
Pattern with error: \`(\` <--HERE-- \`\`
S62 modules passed unittests
utils.ui_text.uiText: a template with no parameters is its english:
Time taken: 5 secs, 527 ms, 108 μs, and 5 hnsecs
858 test(s) run, 0 failed.

OK!
✔ a request is one line of JSON (0.111625ms)
ℹ tests 435
ℹ fail 0
The context of .ai/ names nothing the code lacks.
`;
    assert.deepEqual(filterBuildOutput(passed, { root }), []);
});

test("compile errors: the place and the message, not the source line and its caret", () => {
    const output = `    Building log_tracy ~master: building configuration [log_tracy-test-library]
source/utils/keys.d(254,20): Error: cannot implicitly convert expression \`"str"\` of type \`string\` to \`int\`
unittest { int x = "str"; undefinedFn(); }
                   ^
/p/dlt/source/utils/fsm.d(12): Deprecation: \`foo\` is deprecated
source/utils/keys.d(254): Error: undefined identifier \`undefinedFn\`
unittest { int x = "str"; undefinedFn(); }
                          ^
Error ldc2 failed with exit code 1.
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "source/utils/keys.d(254,20): Error: cannot implicitly convert expression `\"str\"` of type `string` to `int`",
        "source/utils/fsm.d(12): Deprecation: `foo` is deprecated",
        "source/utils/keys.d(254): Error: undefined identifier `undefinedFn`",
        "Error ldc2 failed with exit code 1.",
    ]);
});

test("a failed unittest: the exception, its message and the frames of the project's code", () => {
    const output = `     Running build/osx-aarch64-unittest/log_tracy-test-library
core.exception.AssertError@source/utils/keys.d(254): probe failure
second line of the message
----------------
??:? _d_assert_msg [0x1008611eb]
/p/dlt/source/utils/keys.d:254 void utils.keys.__unittest_L254_C1() [0x100632de7]
/p/dlt/source/utils/keys.d utils.keys.__unittest [0x100632e07]
??:? runModuleUnitTests [0x100874443]
/opt/homebrew/Cellar/ldc/1.43.0/include/dlang/ldc/core/internal/entrypoint.d:42 main [0x1007f30d7]
core.exception.ArrayIndexError@source/utils/fsm.d(278): index [5] is out of bounds for array of length 1
----------------
??:? onArrayIndexError [0x10088276f]
/p/dlt/source/utils/fsm.d:278 void utils.fsm.__unittest_L278_C1() [0x1006338db]
Opening file: /logs/a.log
Test toString memory safety (dangling pointer check)
S2/62 modules FAILED unittests
tring after temporary destruction: [1,2,3]
Error Program exited with code 1
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "source/utils/keys.d(254): AssertError: probe failure",
        "  second line of the message",
        "    at source/utils/keys.d:254 void utils.keys.__unittest_L254_C1()",
        "source/utils/fsm.d(278): ArrayIndexError: index [5] is out of bounds for array of length 1",
        "    at source/utils/fsm.d:278 void utils.fsm.__unittest_L278_C1()",
        "2/62 modules FAILED unittests",
        "Error Program exited with code 1",
    ]);
});

test("failed unittests of unit-threaded: the exceptions, the frames of the project, the names, the summary", () => {
    const output = `     Running build/osx-aarch64-unittest/log_tracy
utils.ui_text.probe: passes after:
-------------------------------

core.exception.AssertError@source/utils/ui_text.d(197): one is not two
----------------
??:? _d_assert_msg [0x102f6cadb]
/p/dlt/source/utils/ui_text.d:197 void utils.ui_text.__unittest_L197_C26() [0x102c1f097]


    object.Exception@source/utils/ui_text.d(198): boom
----------------
/p/dlt/source/utils/ui_text.d:198 void utils.ui_text.__unittest_L198_C20() [0x102c1f123]
/p/dlt/../../../.dub/packages/unit-threaded/2.2.6/unit-threaded/subpackages/runner/source/unit_threaded/runner/testcase.d:293 void unit_threaded.runner.testcase.FunctionTestCase.test() [0x102f2702b]
/p/dlt/../../../.dub/packages/unit-threaded/2.2.6/unit-threaded/subpackages/runner/source/unit_threaded/runner/runner.d:22 _Dmain [0x102e668c7]



Test 'utils.ui_text.probe: assert fails' failed.
Test 'utils.ui_text.probe: throws' failed.


Time taken: 582 ms, 580 μs, and 3 hnsecs
10 test(s) run, 2 failed.

Tests failed!

Error Program exited with code 1
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "source/utils/ui_text.d(197): AssertError: one is not two",
        "    at source/utils/ui_text.d:197 void utils.ui_text.__unittest_L197_C26()",
        "source/utils/ui_text.d(198): Exception: boom",
        "    at source/utils/ui_text.d:198 void utils.ui_text.__unittest_L198_C20()",
        "Test 'utils.ui_text.probe: assert fails' failed.",
        "Test 'utils.ui_text.probe: throws' failed.",
        "10 test(s) run, 2 failed.",
        "Error Program exited with code 1",
    ]);
});

test("a failed JS test: its place, its name and its diff, not node's own frames and fields", () => {
    const output = `✔ the states are not changed in place (0.105084ms)
✖ probe failure (1.358125ms)
ℹ tests 436
ℹ pass 435
ℹ fail 1
ℹ duration_ms 1120.0725

✖ failing tests:

test at tests/js/zz-probe.test.mjs:3:1
✖ probe failure (1.358125ms)
  AssertionError [ERR_ASSERTION]: Expected values to be strictly deep-equal:
  + actual - expected

    {
      a: 1,
  +   b: 2
  -   b: 3
    }

      at TestContext.<anonymous> (file:///p/dlt/tests/js/zz-probe.test.mjs:3:38)
      at Test.runInAsyncScope (node:async_hooks:226:14)
      at startSubtestAfterBootstrap (node:internal/test_runner/harness:387:17) {
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: {
      a: 1
    },
    operator: 'deepStrictEqual'
  }

test at tests/js/other.test.mjs:9:1
✖ other (0.1ms)
  Error: thrown
      at file:///p/dlt/resources/x.js:4:9
      at node:internal/process/task_queues:105:5
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "ℹ fail 1",
        "test at tests/js/zz-probe.test.mjs:3:1",
        "✖ probe failure (1.358125ms)",
        "  AssertionError [ERR_ASSERTION]: Expected values to be strictly deep-equal:",
        "  + actual - expected",
        "    {",
        "      a: 1,",
        "  +   b: 2",
        "  -   b: 3",
        "    }",
        "      at TestContext.<anonymous> (tests/js/zz-probe.test.mjs:3:38)",
        "test at tests/js/other.test.mjs:9:1",
        "✖ other (0.1ms)",
        "  Error: thrown",
        "      at resources/x.js:4:9",
    ]);
});

test("a link that failed: the linker's lines", () => {
    const output = `     Linking log_tracy
Undefined symbols for architecture arm64:
  "_foo", referenced from:
ld: symbol(s) not found for architecture arm64
clang: error: linker command failed with exit code 1 (use -v to see invocation)
Error: /usr/bin/cc failed with status: 1
Error ldc2 failed with exit code 1.
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "Undefined symbols for architecture arm64:",
        "ld: symbol(s) not found for architecture arm64",
        "clang: error: linker command failed with exit code 1 (use -v to see invocation)",
        "Error: /usr/bin/cc failed with status: 1",
        "Error ldc2 failed with exit code 1.",
    ]);
});

test("a failed step none of whose lines is known: its last lines, so a failure never goes silent", () => {
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`);
    lines.splice(5, 0, "");
    assert.deepEqual(filterBuildOutput(lines.join("\n") + "\n", { failed: true, root }),
        Array.from({ length: 15 }, (_, i) => `line ${i + 16}`));
    // the same output of a step that went well: nothing
    assert.deepEqual(filterBuildOutput(lines.join("\n"), { root }), []);
});

test("Windows line ends and paths of the project with backslashes are cut alike", () => {
    const output = "C:\\p\\dlt\\source\\a.d(3): Error: no\r\nError ldc2 failed with exit code 1.\r\n";
    assert.deepEqual(filterBuildOutput(output, { failed: true, root: "C:\\p\\dlt" }),
        ["source\\a.d(3): Error: no", "Error ldc2 failed with exit code 1."]);
});

test("a flood of errors is cut at the limit, saying how many lines are left out and where they are", () => {
    const output = Array.from({ length: filterLimit + 10 }, (_, i) => `source/a.d(${i + 1}): Error: no`).join("\n");
    const brief = filterBuildOutput(output, { failed: true, root, log: "build/x.log" });
    assert.equal(brief.length, filterLimit + 1);
    assert.equal(brief.at(-1), "… 10 more lines: build/x.log");
});

test("a failure told only by a summary line (a crash, a linker of Linux) brings the last lines too", () => {
    const link = `     Linking log_tracy
/usr/bin/ld: source/a.o: in function \`_D3app4mainFZv':
/usr/bin/ld: a.d:(.text+0x10): undefined reference to \`foo'
collect2: error: ld returned 1 exit status
Error: /usr/bin/cc failed with status: 1
Error ldc2 failed with exit code 1.
`;
    assert.deepEqual(filterBuildOutput(link, { failed: true, root }), [
        "/usr/bin/ld: source/a.o: in function `_D3app4mainFZv':",
        "/usr/bin/ld: a.d:(.text+0x10): undefined reference to `foo'",
        "collect2: error: ld returned 1 exit status",
        "Error: /usr/bin/cc failed with status: 1",
        "Error ldc2 failed with exit code 1.",
    ]);
    const crash = `Test int finished
Test bool
Error Program exited with code -11
`;
    assert.deepEqual(filterBuildOutput(crash, { failed: true, root }),
        ["Error Program exited with code -11", "Test int finished", "Test bool"]);
});

test("an exception a passing test prints is no failure, and one without a stack takes no lines after it", () => {
    const logged = `object.Exception@source/a.d(3): expected by the test
next line of the test
`;
    assert.deepEqual(filterBuildOutput(logged, { root }), []);
    assert.deepEqual(filterBuildOutput(logged + "1/2 modules FAILED unittests\n", { failed: true, root }),
        ["source/a.d(3): Exception: expected by the test", "1/2 modules FAILED unittests"]);
    // inside a line it is a message of the program, not a failure of druntime's
    assert.deepEqual(filterBuildOutput("Error loading settings: std.json.JSONException@std/json.d(12): no\n",
        { failed: true, root }), ["Error loading settings: std.json.JSONException@std/json.d(12): no"]);
    // only unit-threaded's indent of four spaces is a report: another one is a message too
    assert.deepEqual(filterBuildOutput("  std.json.JSONException@std/json.d(12): no\nError Program exited with code 1\n",
        { failed: true, root }), ["Error Program exited with code 1", "  std.json.JSONException@std/json.d(12): no"]);
});

test("the lines that go with a compile error: where a template was instantiated", () => {
    const output = `source/utils/x.d(40,5): Error: no property \`foo\` for \`int\`
source/ui/y.d(12,9):        instantiated from here: \`bar!int\`
    bar!int(1);
        ^
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }), [
        "source/utils/x.d(40,5): Error: no property `foo` for `int`",
        "source/ui/y.d(12,9):        instantiated from here: `bar!int`",
    ]);
});

test("frames of the project on Windows (file:///C:/...) and with spaces in the path are the project's", () => {
    const output = `✖ failing tests:

test at tests\\js\\a.test.mjs:3:1
✖ a (1ms)
  Error: thrown
      at file:///C:/p/my%20dlt/resources/x.js:4:9
      at node:internal/process/task_queues:105:5
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root: "C:\\p\\my dlt" }),
        ["test at tests\\js\\a.test.mjs:3:1", "✖ a (1ms)", "  Error: thrown", "      at resources/x.js:4:9"]);
});

test("a folder next to the project whose name starts like it is not the project", () => {
    const output = `core.exception.AssertError@source/a.d(3): no
----------------
/p/dlt-old/source/a.d:3 void a.__unittest_L3_C1() [0x1]
/p/dlt/source/a.d:3 void a.__unittest_L3_C1() [0x2]
`;
    assert.deepEqual(filterBuildOutput(output, { failed: true, root }),
        ["source/a.d(3): AssertError: no", "    at source/a.d:3 void a.__unittest_L3_C1()"]);
});
