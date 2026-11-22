import Foundation
import Darwin

/// PID of the masked child, for the signal-forwarding handler. A global
/// because C signal handlers can't capture context.
private var maskedChildPID: pid_t = 0

/// Runs `path` with `argv` and `env`, with stdout and stderr piped through
/// an `OutputMasker`. stdin is inherited. Returns the exit code mima should
/// exit with: the child's own code, or 128 + signal if it was killed.
///
/// Unlike the plain execve path, mima stays alive for the child's lifetime
/// and holds the secret values in memory to match against. That's the
/// cost of masking, which is why it's opt-in.
func runMasked(path: String, argv: [String], env: [String: String], secrets: [String: String]) throws -> Int32 {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    for fd in outPipe + errPipe { posix_spawn_file_actions_addclose(&actions, fd) }

    // The child gets default dispositions and an empty mask, whatever
    // mima set below. Ignored signals would otherwise survive the exec.
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigdefault(&attr, &defaults)
    posix_spawnattr_setsigmask(&attr, &emptyMask)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        for p in cArgv { free(p) }
        for p in cEnv { free(p) }
    }

    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, path, &actions, &attr, cArgv, cEnv)
    close(outPipe[1])
    close(errPipe[1])
    guard spawnStatus == 0 else {
        close(outPipe[0]); close(errPipe[0])
        throw POSIXError(.init(rawValue: spawnStatus) ?? .EIO)
    }

    // Ctrl-C and Ctrl-\ reach the child directly, since it shares the
    // terminal's foreground process group. mima ignores them and exits
    // when the child does. TERM and HUP sent to mima are forwarded.
    maskedChildPID = pid
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    let forward: @convention(c) (Int32) -> Void = { sig in
        if maskedChildPID > 0 { kill(maskedChildPID, sig) }
    }
    signal(SIGTERM, forward)
    signal(SIGHUP, forward)

    pumpMasked(streams: [(outPipe[0], STDOUT_FILENO), (errPipe[0], STDERR_FILENO)], secrets: secrets)

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    maskedChildPID = 0
    let signalNumber = status & 0x7f
    return signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
}

/// Copies each read end to its destination through its own masker until
/// every stream reaches EOF.
private func pumpMasked(streams: [(read: Int32, write: Int32)], secrets: [String: String]) {
    var maskers = streams.map { _ in OutputMasker(secrets: secrets) }
    var open = streams.map { _ in true }
    var writable = streams.map { _ in true }
    var buffer = [UInt8](repeating: 0, count: 65536)

    while open.contains(true) {
        var fds = streams.indices.filter { open[$0] }.map { pollfd(fd: streams[$0].read, events: Int16(POLLIN), revents: 0) }
        let indices = streams.indices.filter { open[$0] }
        guard poll(&fds, nfds_t(fds.count), -1) >= 0 || errno == EINTR else { break }
        for (k, idx) in indices.enumerated() where fds[k].revents != 0 {
            let n = read(streams[idx].read, &buffer, buffer.count)
            if n > 0 {
                let masked = maskers[idx].feed(Array(buffer[0..<n]))
                if writable[idx] && !writeAll(streams[idx].write, masked) {
                    // Our reader went away (e.g. `| head`). Close our end so
                    // the child gets EPIPE/SIGPIPE, as it would without mima.
                    writable[idx] = false
                    close(streams[idx].read)
                    open[idx] = false
                }
            } else if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) {
                if writable[idx] { _ = writeAll(streams[idx].write, maskers[idx].finish()) }
                close(streams[idx].read)
                open[idx] = false
            }
        }
    }
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += n
    }
    return true
}
