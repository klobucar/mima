import Foundation

/// Variables `mima run --scrub` keeps from the parent environment, on
/// top of every `LC_*` locale variable.
///
/// This is deliberately minimal: just enough for a typical CLI to find
/// binaries, its config directory, the terminal, and the locale.
///
/// - `TMPDIR` is kept because macOS points it at a per-user directory.
///   Without it, most tools fall back to the shared, world-writable `/tmp`.
/// - `SSH_AUTH_SOCK` is deliberately left out. It lets the child
///   authenticate as you over SSH and sign as you, for example pushing to
///   your git remotes. Pass `--keep SSH_AUTH_SOCK` if the child needs it.
let scrubSafelist: Set<String> = [
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR", "LANG", "TZ",
]

func isScrubSafelisted(_ name: String) -> Bool {
    scrubSafelist.contains(name) || name.hasPrefix("LC_")
}

/// Builds the environment for the child process.
///
/// - Inherit (default): the parent environment plus the group's secrets.
///   A secret wins over a parent variable with the same name.
/// - Scrub: only safelisted parent variables, plus any named in `keep`,
///   plus the group's secrets. Nothing else from the parent reaches the
///   child.
func buildChildEnvironment(
    parent: [String: String],
    secrets: [String: String],
    scrub: Bool,
    keep: [String] = []
) -> [String: String] {
    var env: [String: String]
    if scrub {
        let kept = Set(keep)
        env = parent.filter { isScrubSafelisted($0.key) || kept.contains($0.key) }
    } else {
        env = parent
    }
    env.merge(secrets) { _, secret in secret }
    return env
}
