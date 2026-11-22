import Foundation
import Testing
@testable import Guava

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("captures output streams and the exit status")
    func capturesOutput() async {
        let result = await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])

        #expect(result.exitCode == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(!result.success)
        #expect(result.failureMessage == "err")
    }

    private func failed(stderr: String, stdout: String = "") -> ProcessResult {
        ProcessResult(exitCode: 1, stdout: stdout, stderr: stderr, timedOut: false, wasCancelled: false, launchError: nil)
    }

    @Test("starts a failure message at the line that names the error, not at the closing advice")
    func summarisesFromFirstError() {
        // What npm prints when asked for a package its registry does not have.
        let npm = failed(stderr: """
        npm error code E404
        npm error 404 Not Found - GET https://registry.npmjs.org/stray-folder - Not found
        npm error 404
        npm error 404  'stray-folder@*' is not in this registry.
        npm error 404
        npm error 404 Note that you can also install from a
        npm error 404 tarball, folder, http url, or git url.
        npm error A complete log of this run can be found in: /Users/me/.npm/_logs/debug-0.log
        """)

        let lines = npm.failureMessage.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "npm error code E404")
        #expect(lines[1].contains("GET https://registry.npmjs.org/stray-folder"))
        #expect(!npm.failureMessage.contains("tarball, folder"))

        // Progress first, the error last.
        let rustup = failed(stderr: "info: syncing channel updates\ninfo: downloading component\nerror: could not download file\n")
        #expect(rustup.failureMessage == "error: could not download file")
    }

    @Test("falls back to the last lines when nothing names an error")
    func summarisesFromTail() {
        let result = failed(stderr: "", stdout: "one\ntwo\nthree\nfour\nfive\nsix\n")

        #expect(result.failureMessage == "three\nfour\nfive\nsix")
        #expect(failed(stderr: " \n", stdout: "").failureMessage == "Exited with status 1")
    }

    @Test("reports each line as it is produced, including an unterminated last line")
    func streamsLines() async {
        let lines = Collector<String>()
        let result = await ProcessRunner.run(
            "/bin/sh", ["-c", "printf 'one\\ntwo\\r\\nthree'"]
        ) { line, stream in
            if stream == .stdout { lines.append(line) }
        }

        #expect(result.success)
        #expect(lines.values == ["one", "two", "three"])
    }

    @Test("stops a process that exceeds its timeout")
    func enforcesTimeout() async {
        let started = Date()
        let result = await ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)

        #expect(result.timedOut)
        #expect(!result.success)
        #expect(result.failureMessage == "Timed out")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("stops the process when the calling task is cancelled")
    func honoursCancellation() async {
        let started = Date()
        let task = Task { await ProcessRunner.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(!result.success)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("returns a launch error instead of crashing when the executable is missing")
    func reportsLaunchFailure() async {
        let result = await ProcessRunner.run("/nonexistent/guava-tool", ["--version"])

        #expect(result.launchError != nil)
        #expect(!result.success)
    }

    @Test("does not wait for a background child that keeps the output pipe open")
    func doesNotHangOnInheritedPipes() async {
        let started = Date()
        let result = await ProcessRunner.run("/bin/sh", ["-c", "sleep 8 & echo started"])

        #expect(result.success)
        #expect(result.stdout.contains("started"))
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test("keeps only the most recent output when the capture limit is exceeded")
    func boundsCapturedOutput() async {
        let result = await ProcessRunner.run(
            "/bin/sh", ["-c", "i=0; while [ $i -lt 400 ]; do echo line-$i; i=$((i+1)); done"],
            captureLimit: 1024
        )

        #expect(result.success)
        #expect(result.stdout.utf8.count <= 1024)
        #expect(result.stdout.contains("line-399"))
        #expect(!result.stdout.contains("line-0\n"))
    }
}

@Suite("ToolEnvironment")
struct ToolEnvironmentTests {

    @Test("finds executables on the inherited PATH and ignores directories and plain files")
    func resolvesExecutables() throws {
        let scratch = try TemporaryDirectory()
        let bin = try scratch.makeDirectory("bin")
        try scratch.write("#!/bin/sh\n", to: "bin/tool", executable: true)
        try scratch.write("not executable", to: "bin/notes")
        try scratch.makeDirectory("bin/folder")

        let environment = ToolEnvironment(
            home: scratch.url, inherited: ["PATH": bin.path], includeSystemLocations: false
        )

        #expect(environment.which("tool") == bin.appendingPathComponent("tool").path)
        #expect(environment.which("notes") == nil)
        #expect(environment.which("folder") == nil)
        #expect(environment.which("missing") == nil)
    }

    @Test("puts per-user tool directories ahead of the inherited PATH")
    func prefersUserDirectories() throws {
        let scratch = try TemporaryDirectory()
        let userBin = try scratch.makeDirectory(".bun/bin")
        let other = try scratch.makeDirectory("other")

        let environment = ToolEnvironment(
            home: scratch.url, inherited: ["PATH": other.path], includeSystemLocations: false
        )

        #expect(environment.searchPaths == [userBin.path, other.path])
        #expect(environment.environment["PATH"] == "\(userBin.path):\(other.path)")
        #expect(environment.environment["HOME"] == scratch.url.path)
    }
}

@Suite("ANSI stripping")
struct ANSIStrippingTests {

    @Test("removes colour and cursor sequences but keeps the text")
    func stripsSequences() {
        #expect("\u{1B}[1;32m==>\u{1B}[0m Upgrading\u{1B}[2K".strippingANSI == "==> Upgrading")
        #expect("plain text".strippingANSI == "plain text")
    }
}
