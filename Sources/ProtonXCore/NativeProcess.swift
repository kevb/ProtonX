import Foundation
import Darwin

/// Private stdin/stdout pipes. No shell, passwords in argv, inherited Proton credentials, or raw error logging.
public final class NativeProcess: HelperRunning, @unchecked Sendable {
    private let executable: URL
    private let directory: URL
    private let timeout: Duration
    private let lock = NSLock()
    private var active: [UUID: Process] = [:]
    public init(executable: URL, directory: URL, timeout: Duration = .seconds(120)) {
        self.executable = executable; self.directory = directory; self.timeout = timeout
    }
    public func cancelAll() {
        let processes = lock.withLock { Array(active.values) }
        for process in processes { Self.stop(process) }
    }
    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
    public func run(_ command: HelperCommand, challenge: ChallengeHandler? = nil) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProtonXError.helperMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = command.arguments
        // Deliberate allowlist: proxy, debug, key-provider and password variables from a developer shell cannot override this session.
        process.environment = [
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PROTONX_NATIVE": "1", "PROTON_PASS_SESSION_DIR": directory.path,
            "PROTON_PASS_KEY_PROVIDER": "keyring", "PROTON_PASS_DISABLE_TELEMETRY": "1",
            "PASS_LOG_LEVEL": "off", "MUON_LOG_LEVEL": "off"
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Registration and start are atomic with respect to cancelAll.
            try lock.withLock {
                try Task.checkCancellation()
                active[id] = process
                do { try process.run() } catch { active.removeValue(forKey: id); throw error }
            }
            defer {
                Self.stop(process)
                lock.withLock { _ = active.removeValue(forKey: id) }
                try? stdin.fileHandleForWriting.close()
            }
            if Task.isCancelled { throw CancellationError() }
            let watchdog = Task.detached { [timeout] in
                try? await Task.sleep(for: challenge == nil ? timeout : .seconds(300))
                if !Task.isCancelled { Self.stop(process) }
            }
            defer { watchdog.cancel() }
            let output = Task.detached {
                do { return try await Self.readBounded(stdout.fileHandleForReading) }
                catch { Self.stop(process); throw error }
            }
            let errors = Task.detached {
                var buffer = Data()
                while let chunk = try await Self.readAvailable(stderr.fileHandleForReading, count: 4096), !chunk.isEmpty {
                    buffer.append(chunk)
                    guard buffer.count < 65536 else { Self.stop(process); throw ProtonXError.outputTooLarge }
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer.prefix(upTo: newline)
                        buffer.removeSubrange(...newline)
                        guard line.starts(with: Data("PROTONX:".utf8)) else { continue }
                        guard let challenge else { Self.stop(process); throw ProtonXError.invalidResponse }
                        let request = try JSONDecoder().decode(AuthChallenge.self, from: line.dropFirst(8))
                        do {
                            let answer = try await challenge(request)
                            var reply = try JSONEncoder().encode(answer); reply.append(10)
                            try stdin.fileHandleForWriting.write(contentsOf: reply)
                        } catch { Self.stop(process); throw error }
                    }
                }
                // Upstream stderr may include account identifiers or secrets. It is deliberately discarded.
            }
            if let input = command.input {
                // Templates are bounded by the editor; write in a worker so the UI never blocks on a full pipe.
                try await Self.writeInput(input, handle: stdin.fileHandleForWriting)
            } else if challenge == nil { try stdin.fileHandleForWriting.close() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); continuation.resume() }
            }
            let result: Data
            do { result = try await output.value; try await errors.value }
            catch { Self.stop(process); throw error }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw ProtonXError.helperFailed(process.terminationStatus) }
            return result
        } onCancel: { Self.stop(process) }
    }
    private static func readBounded(_ handle: FileHandle) async throws -> Data {
        var data = Data()
        while let part = try await readAvailable(handle, count: 32768), !part.isEmpty {
            guard data.count + part.count <= 16 * 1024 * 1024 else { throw ProtonXError.outputTooLarge }
            data.append(part)
        }
        return data
    }
    private static func readAvailable(_ handle: FileHandle, count: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var bytes = [UInt8](repeating: 0, count: count)
                var size: Int
                repeat { size = Darwin.read(handle.fileDescriptor, &bytes, count) } while size < 0 && errno == EINTR
                if size < 0 { continuation.resume(throwing: ProtonXError.invalidResponse) }
                else if size == 0 { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data(bytes.prefix(size))) }
            }
        }
    }
    private static func writeInput(_ data: Data, handle: FileHandle) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { try handle.write(contentsOf: data); try handle.close(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

}
