// What the scripts dub runs as hooks (dub.sdl) share: whether scripts/build.mjs test, which runs
// the same steps itself, asked them to stay out (NO_DUB_HOOKS). Tests: tests/js/test-js-script.test.mjs.

/// The variable that says so, set by scripts/build.mjs for the `dub test` it runs.
export const noHooksVariable = "NO_DUB_HOOKS";

/// Whether the hooks of dub are off in this environment.
export function hooksOff(env) {
    return (env[noHooksVariable] ?? "") !== "";
}
