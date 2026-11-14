// Runs the tests of Log Tracy: `node scripts/build.mjs test` under a name that says so. The
// options: `node scripts/test.mjs --help` (testUsage in build.mjs).
// Tests: tests/js/test-script.test.mjs.
import { commands, runCommandLine, testUsage } from "./build.mjs";

const argv = process.argv.slice(2);
if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(testUsage);
} else if (argv.some((arg) => commands.includes(arg))) {
    console.error("test.mjs runs the tests only, it takes no command: --module, --arch, --brief (--help)");
    process.exitCode = 1;
} else {
    runCommandLine(["test", ...argv]);
}
