import Foundation

/// Walks a `PATH`-style string looking for an executable file named
/// `name`. Mirrors the lookup semantics of `execvp(3)` so users see the
/// same resolution behaviour they'd get from the shell.
///
/// Returns `nil` if `name` cannot be found or is not executable by the
/// current effective UID.
func resolveExecutable(_ name: String, pathEnv: String) -> String? {
    let fm = FileManager.default
    for dir in pathEnv.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = "\(dir)/\(name)"
        if fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}
