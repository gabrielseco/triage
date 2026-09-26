import Testing

@testable import TriageCore

@Test func capturesStatusAndBothStreams() async throws {
    let out = try await Subprocess.run("/bin/sh", ["-c", "echo ' hi '; echo oops >&2; exit 3"])
    #expect(out.status == 3)
    #expect(out.trimmedStdout == "hi")
    #expect(out.stderr == "oops\n")
}

@Test func moreStderrThanAPipeHoldsDoesNotDeadlock() async throws {
    // ~200 KB on stderr, well past the 64 KB pipe buffer, before anything reaches stdout.
    let out = try await Subprocess.run("/bin/sh", ["-c", "head -c 200000 /dev/zero >&2; echo done"])
    #expect(out.status == 0)
    #expect(out.trimmedStdout == "done")
    #expect(out.stderr.utf8.count == 200_000)
}
