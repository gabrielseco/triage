import Darwin
import Foundation

extension Subprocess {
    public enum Event: Sendable {
        case stdout(Data)
        case stderr(Data)
        case exited(Int32)
    }

    public enum SessionError: Error, Sendable {
        case inputClosed
        case inputWriteFailed(Int32)
    }

    public struct Session: Sendable {
        public let events: AsyncStream<Event>
        private let state: StreamingState

        fileprivate init(events: AsyncStream<Event>, state: StreamingState) {
            self.events = events
            self.state = state
        }

        public func send(_ data: Data) async throws {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.inputQueue.async {
                        do {
                            try state.write(data)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                state.terminate()
            }
        }

        public func finishInput() { state.finishInput() }
        public func terminate() { state.terminate() }
    }

    public static func start(
        _ executable: String, _ arguments: [String], directory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> Session {
        try Task.checkCancellation()
        let session: Session = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment
                let input = Pipe(), output = Pipe(), error = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                try? input.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                try? error.fileHandleForWriting.close()
                let pair = AsyncStream<Event>.makeStream()
                let state = StreamingState(
                    process: process, input: input.fileHandleForWriting,
                    output: output.fileHandleForReading, error: error.fileHandleForReading,
                    continuation: pair.continuation)
                pair.continuation.onTermination = { @Sendable _ in state.terminate() }
                state.begin()
                continuation.resume(returning: Session(events: pair.stream, state: state))
            }
        }
        if Task.isCancelled {
            session.terminate()
            throw CancellationError()
        }
        return session
    }
}

// Mutable lifecycle flags are protected by lock. Each descriptor has exactly one GCD owner:
// inputQueue writes/closes stdin; each drain block reads/closes its pipe. Process waits run on GCD.
// Nonblocking descriptors and short poll intervals let shutdown interrupt pipe pressure without
// closing a descriptor underneath a syscall or blocking the Swift cooperative executor.
private final class StreamingState: @unchecked Sendable {
    let inputQueue = DispatchQueue(label: "Triage.Subprocess.stdin")
    private let lock = NSLock()
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let continuation: AsyncStream<Subprocess.Event>.Continuation
    private let ownedGroup: pid_t?
    private let childPID: pid_t
    private var stopped = false
    private var inputClosed = false
    private var exitedAt: Date?

    init(
        process: Process, input: FileHandle, output: FileHandle, error: FileHandle,
        continuation: AsyncStream<Subprocess.Event>.Continuation
    ) {
        self.process = process
        self.input = input
        self.output = output
        self.error = error
        self.continuation = continuation
        let pid = process.processIdentifier
        childPID = pid
        let group = getpgid(pid)
        ownedGroup = group == pid && group != getpgrp() ? group : nil
        for handle in [input, output, error] {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        // Suppress SIGPIPE for this descriptor only; never change the application's signal policy.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func begin() {
        let drains = DispatchGroup()
        DispatchQueue.global().async(group: drains) { self.drain(self.output, stdout: true) }
        DispatchQueue.global().async(group: drains) { self.drain(self.error, stdout: false) }
        DispatchQueue.global().async {
            self.process.waitUntilExit()
            self.lock.lock()
            self.exitedAt = Date()
            self.inputClosed = true
            self.lock.unlock()
            self.inputQueue.async { try? self.input.close() }
            drains.wait()
            self.continuation.yield(.exited(self.process.terminationStatus))
            self.continuation.finish()
        }
    }

    func finishInput() {
        lock.lock()
        inputClosed = true
        lock.unlock()
        inputQueue.async { try? self.input.close() }
    }

    func terminate() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        inputClosed = true
        let alive = exitedAt == nil
        if alive { signal(SIGTERM) }
        lock.unlock()
        inputQueue.async { try? self.input.close() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            self.lock.lock()
            if self.exitedAt == nil || self.ownedGroup != nil { self.signal(SIGKILL) }
            self.lock.unlock()
        }
    }

    private func signal(_ value: Int32) {
        // Foundation may create a separate group. Never signal the app's inherited process group.
        _ = kill(ownedGroup.map { -$0 } ?? childPID, value)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                lock.lock()
                let closed = inputClosed || stopped || exitedAt != nil
                lock.unlock()
                if closed { throw Subprocess.SessionError.inputClosed }
                return
            }
            var offset = 0
            while offset < buffer.count {
                lock.lock()
                let closed = inputClosed || stopped || exitedAt != nil
                lock.unlock()
                guard !closed else { throw Subprocess.SessionError.inputClosed }
                let count = Darwin.write(input.fileDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno != EINTR && errno != EAGAIN {
                    throw Subprocess.SessionError.inputWriteFailed(errno)
                } else {
                    var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 50)
                }
            }
            lock.lock()
            let closed = inputClosed || stopped || exitedAt != nil
            lock.unlock()
            if closed { throw Subprocess.SessionError.inputClosed }
        }
    }

    private func drain(_ handle: FileHandle, stdout: Bool) {
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                continuation.yield(stdout ? .stdout(data) : .stderr(data))
            } else if count == 0 {
                return
            } else if errno != EINTR && errno != EAGAIN {
                return
            } else {
                lock.lock()
                let deadlinePassed = exitedAt.map { Date().timeIntervalSince($0) >= 1 } ?? false
                let cancelled = stopped
                lock.unlock()
                // Descendants can inherit output pipes. Bound cleanup after exit or cancellation.
                if cancelled || deadlinePassed { return }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 50)
            }
        }
    }
}
