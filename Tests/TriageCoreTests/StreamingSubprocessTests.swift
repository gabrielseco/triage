import Darwin
import Foundation
import Testing

@testable import TriageCore

@Suite(.timeLimit(.minutes(1)))
struct StreamingSubprocessTests {
    @Test func deliversBytesBeforeExitAndRetainsSplitUTF8() async throws {
        let session = try await Subprocess.start(
            "/bin/sh", ["-c", "printf '\\342'; read line; printf '\\202\\254'; echo problem >&2; exit 7"])
        var iterator = session.events.makeAsyncIterator()
        let first = await iterator.next()
        guard case .stdout(let data) = first else {
            Issue.record("Expected stdout before the child receives input")
            session.terminate()
            return
        }
        #expect(data == Data([0xE2]))
        try await session.send(Data("go\n".utf8))
        var stdout = data
        var stderr = Data()
        var status: Int32?
        while let event = await iterator.next() {
            switch event {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            case .exited(let code): status = code
            }
        }
        #expect(stdout == Data([0xE2, 0x82, 0xAC]))
        #expect(String(decoding: stderr, as: UTF8.self) == "problem\n")
        #expect(status == 7)
    }

    @Test func drainsBothPipesUnderPressureBeforeExit() async throws {
        let session = try await Subprocess.start(
            "/bin/sh", ["-c", "head -c 300000 /dev/zero & head -c 300000 /dev/zero >&2 & wait"])
        var stdout = 0, stderr = 0
        var exited = false
        for await event in session.events {
            switch event {
            case .stdout(let data):
                #expect(!exited)
                stdout += data.count
            case .stderr(let data):
                #expect(!exited)
                stderr += data.count
            case .exited(let status):
                exited = true
                #expect(status == 0)
                #expect(stdout == 300_000)
                #expect(stderr == 300_000)
            }
        }
        #expect(exited)
    }

    @Test func keepsInputOpenAcrossRepeatedTurnsAndFinishesIt() async throws {
        let session = try await Subprocess.start(
            "/bin/sh", ["-c", "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"])
        var iterator = session.events.makeAsyncIterator()
        for line in ["first", "second", "third"] {
            try await session.send(Data("\(line)\n".utf8))
            guard case .stdout(let data) = await iterator.next() else {
                Issue.record("Expected a response to each turn")
                session.terminate()
                return
            }
            #expect(String(decoding: data, as: UTF8.self) == "\(line)\n")
        }
        session.finishInput()
        guard case .exited(let status) = await iterator.next() else {
            Issue.record("Expected EOF to let the child exit")
            return
        }
        #expect(status == 0)
        await #expect(throws: Subprocess.SessionError.self) { try await session.send(Data("late".utf8)) }
    }

    @Test func reportsStartupAndBrokenInputFailures() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await Subprocess.start("/does/not/exist/triage-fixture", [])
        }
        let session = try await Subprocess.start("/bin/sh", ["-c", "exec 0<&-; echo ready; sleep 1"])
        var iterator = session.events.makeAsyncIterator()
        _ = await iterator.next()
        await #expect(throws: Subprocess.SessionError.self) { try await session.send(Data("closed\n".utf8)) }
        session.terminate()
        while await iterator.next() != nil {}
    }

    @Test func terminationUnblocksPressuredInputAndEscalatesIgnoringChild() async throws {
        let session = try await Subprocess.start("/bin/sh", ["-c", "trap '' TERM; echo ready; sleep 20"])
        var iterator = session.events.makeAsyncIterator()
        _ = await iterator.next()
        let writer = Task { try await session.send(Data(repeating: 65, count: 2_000_000)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        session.terminate()
        await #expect(throws: Subprocess.SessionError.self) { try await writer.value }
        var status: Int32?
        while let event = await iterator.next() {
            if case .exited(let code) = event { status = code }
        }
        #expect(status != nil)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func cancellingEventConsumerStopsOwnedChildWithoutSignallingOurGroup() async throws {
        let session = try await Subprocess.start("/bin/sh", ["-c", "echo $$; exec sleep 20"])
        var iterator = session.events.makeAsyncIterator()
        guard case .stdout(let data) = await iterator.next(),
            let pid = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("Expected fixture pid")
            session.terminate()
            return
        }
        let parentGroup = getpgrp()
        let consumer = Task { for await _ in session.events {} }
        consumer.cancel()
        await consumer.value
        for _ in 0..<50 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(pid, 0) == -1)
        #expect(getpgrp() == parentGroup)
    }

    @Test func cancellationOfPressuredWriteStopsTheSession() async throws {
        let session = try await Subprocess.start("/bin/sh", ["-c", "echo ready; exec sleep 20"])
        var iterator = session.events.makeAsyncIterator()
        _ = await iterator.next()
        let writer = Task { try await session.send(Data(repeating: 65, count: 2_000_000)) }
        try await Task.sleep(for: .milliseconds(100))
        writer.cancel()
        await #expect(throws: (any Error).self) { try await writer.value }
        var exited = false
        while let event = await iterator.next() {
            if case .exited = event { exited = true }
        }
        #expect(exited)
    }

    @Test func terminationSignalsOnlyAnOwnedGroupAndKillsItsIgnoringDescendant() async throws {
        let session = try await Subprocess.start(
            "/bin/sh", ["-c", "trap '' TERM; sleep 20 & echo $$:$!; wait"])
        var iterator = session.events.makeAsyncIterator()
        guard case .stdout(let data) = await iterator.next() else {
            Issue.record("Expected process identifiers")
            session.terminate()
            return
        }
        let identifiers = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Int32($0) }
        #expect(identifiers.count == 2)
        guard identifiers.count == 2 else {
            session.terminate()
            return
        }
        let pid = identifiers[0], descendant = identifiers[1]
        let group = getpgid(pid)
        let ownedGroup = group == pid && group != getpgrp()
        session.terminate()
        while await iterator.next() != nil {}
        if ownedGroup {
            for _ in 0..<50 where kill(descendant, 0) == 0 {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(kill(descendant, 0) == -1)
        } else {
            // An inherited group belongs to the test runner. The fallback must leave it alone.
            #expect(kill(descendant, 0) == 0)
            _ = kill(descendant, SIGKILL)
        }
    }

    @Test func forwardsDirectoryAndEnvironment() async throws {
        let session = try await Subprocess.start(
            "/bin/sh", ["-c", "printf '%s|%s' \"$PWD\" \"$TRIAGE_FIXTURE\""],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: ["TRIAGE_FIXTURE": "value"])
        var output = Data()
        for await event in session.events {
            if case .stdout(let data) = event { output.append(data) }
        }
        #expect(
            String(decoding: output, as: UTF8.self)
                == "/private/tmp|value")
    }
}
