import Foundation

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// One token controls one running command. Cancellation is permanent and thread-safe.
final class ProcessCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t?

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let pid = pid { _ = kill(-pid, SIGKILL) }
    }

    fileprivate func launch(_ body: () throws -> pid_t) throws -> pid_t {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw Failure.message("Process cancelled.") }
        guard pid == nil else { throw Failure.message("Cancellation token already in use.") }
        let child = try body()
        pid = child
        return child
    }

    fileprivate func poll(_ child: pid_t, status: inout Int32) -> (pid_t, Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = waitpid(child, &status, WNOHANG)
        if result != 0 && !(result == -1 && errno == EINTR) {
            // Do not leave background children running after the leader exits.
            if result == child { _ = kill(-child, SIGKILL) }
            pid = nil
        }
        return (result, cancelled)
    }
}

func run(_ executable: String, _ arguments: [String], directory: URL, outputDirectory: URL? = nil, cancellation: ProcessCancellation? = nil) throws -> String {
    guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else { throw Failure.message("Executable not found or not executable: \(executable)") }
    let output = (outputDirectory ?? directory).appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.message("Could not create temporary output file.") }
    let handle = try FileHandle(forWritingTo: output); defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
    let errorOutput = (outputDirectory ?? directory).appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: errorOutput.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.message("Could not create temporary error file.") }
    defer { try? FileManager.default.removeItem(at: errorOutput) }
    let errorHandle = try FileHandle(forWritingTo: errorOutput); defer { try? errorHandle.close() }
    // A fresh process group lets cancellation reach shell scripts and their children.
    // The shell only changes directory and execs the requested executable; arguments
    // are passed as positional parameters, never interpolated into shell code.
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errorHandle.fileDescriptor, STDERR_FILENO)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    let argv = ["/bin/sh", "-c", "cd -- \"$1\" || exit 125; shift; exec \"$@\"", "runner", directory.path, executable] + arguments
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let argPointers = argv.map { strdup($0) } + [nil]
    let envPointers = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for p in argPointers + envPointers { free(p) } }
    let token = cancellation ?? ProcessCancellation()
    let pid = try token.launch {
        var child: pid_t = 0
        let result = argPointers.withUnsafeBufferPointer { args in
            envPointers.withUnsafeBufferPointer { environment in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, args.baseAddress!, environment.baseAddress!)
            }
        }
        guard result == 0 else { throw Failure.message("Could not launch process: \(String(cString: strerror(result)))") }
        return child
    }
    var status: Int32 = 0
    var waited: pid_t = 0
    var wasCancelled = false
    repeat {
        (waited, wasCancelled) = token.poll(pid, status: &status)
        if waited == 0 || (waited == -1 && errno == EINTR) { usleep(10_000) }
    } while waited == 0 || (waited == -1 && errno == EINTR)
    guard waited == pid else { throw Failure.message("Could not wait for process.") }
    if wasCancelled { throw Failure.message("Process cancelled.") }
    try handle.synchronize()
    let data = try Data(contentsOf: output)
    let text = String(decoding: data.prefix(1_000_000), as: UTF8.self)
    if status != 0 {
        try errorHandle.synchronize()
        let errors = String(decoding: try Data(contentsOf: errorOutput).prefix(1_000_000), as: UTF8.self)
        throw Failure.message("\(URL(fileURLWithPath: executable).lastPathComponent) failed (status \(status)):\n\(text)\n\(errors)")
    }
    return text
}
