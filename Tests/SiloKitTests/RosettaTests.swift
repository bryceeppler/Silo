import Foundation
import Testing
@testable import SiloKit

/// Issue #7: on a Mac without Rosetta every wine spawn failed with "Bad CPU type in executable".
@Suite("Rosetta")
struct RosettaTests {

    /// A Mach-O whose CPU type (PowerPC) no current Mac can run — the kernel refuses it with `EBADARCH`, the
    /// exact error an x86_64 wine gets on a Rosetta-less Mac, reproducible whether or not Rosetta is present.
    private func foreignArchExecutable(_ tmp: TempDir) throws -> URL {
        var header = Data()
        for word: UInt32 in [0xfeedface, 18, 0, 2, 0, 0, 0] {   // MH_MAGIC, CPU_TYPE_POWERPC, …, MH_EXECUTE
            withUnsafeBytes(of: word.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(Data(count: 4096))
        let url = tmp.url.appendingPathComponent("ppc")
        try header.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("A foreign-arch spawn reports Rosetta missing, not 'Bad CPU type' (run)")
    func runTranslatesEBADARCH() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try foreignArchExecutable(tmp)
        await #expect(throws: Rosetta.RosettaError.notInstalled) {
            _ = try await SystemProcessRunner().run(executable: exe, arguments: [], environment: [:],
                                                    currentDirectory: nil)
        }
    }

    @Test("A foreign-arch spawn reports Rosetta missing (spawnDetached)")
    func spawnTranslatesEBADARCH() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try foreignArchExecutable(tmp)
        await #expect(throws: Rosetta.RosettaError.notInstalled) {
            try await SystemProcessRunner().spawnDetached(
                executable: exe, arguments: [], environment: [:], currentDirectory: nil,
                logURL: tmp.url.appendingPathComponent("log"))
        }
    }

    @Test("Other spawn errors pass through untouched")
    func otherErrorsPassThrough() {
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect((Rosetta.translating(missing) as NSError) == missing)
        #expect(Rosetta.RosettaError.notInstalled.localizedDescription == "Rosetta 2 isn't installed.")
    }

    @Test("Detection keys off Rosetta's installed payload on Apple Silicon (macOS 27 and earlier)")
    func detection() {
        #if arch(arm64)
        #expect(Rosetta.isInstalled { $0 == "/Library/Apple/usr/libexec/oah/libRosettaRuntime" })   // macOS 27
        #expect(Rosetta.isInstalled { $0 == "/Library/Apple/usr/libexec/oahd" })                   // ≤ 26
        // macOS 27's sealed-volume daemon exists with or without Rosetta — it must NOT count.
        #expect(!Rosetta.isInstalled { $0 == "/usr/libexec/rosetta/oahd" })
        #expect(!Rosetta.isInstalled { _ in false })
        #else
        #expect(Rosetta.isInstalled { _ in false })   // Intel runs x86_64 natively
        #endif
    }

    @Test("install runs softwareupdate --install-rosetta --agree-to-license")
    func installInvocation() async throws {
        let fake = FakeProcessRunner()
        try await Rosetta.install(runner: fake)
        #expect(fake.lastInvocation?.executable.path == "/usr/sbin/softwareupdate")
        #expect(fake.lastInvocation?.arguments == ["--install-rosetta", "--agree-to-license"])
    }

    @Test("On this Mac the probe agrees with whether an x86_64 binary actually runs")
    func probeMatchesReality() async throws {
        #if arch(arm64)
        let result = try? await SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/arch"), arguments: ["-x86_64", "/usr/bin/true"],
            environment: [:], currentDirectory: nil)
        #expect(Rosetta.isInstalled() == (result?.succeeded == true))
        #endif
    }

    @Test("A failed install surfaces softwareupdate's own message")
    func installFailure() async {
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("No network\n".utf8)))
        await #expect(throws: Rosetta.RosettaError.installFailed("No network")) {
            try await Rosetta.install(runner: fake)
        }
    }

    @Test("SteamBottle installs Rosetta only when it's missing, and never blocks setup on failure")
    func bottleEnsure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let paths = AppPaths(supportDir: tmp.url)

        let present = SteamBottle(runner: fake, paths: paths, rosettaInstalled: { true })
        #expect(await present.ensureRosetta() == false)
        #expect(fake.invocations.isEmpty)

        let absent = SteamBottle(runner: fake, paths: paths, rosettaInstalled: { false })
        fake.queueResult(ProcessResult(exitCode: 1))           // install fails → still returns, no throw
        #expect(await absent.ensureRosetta() == true)
        #expect(fake.invocations.map(\.executable.path) == ["/usr/sbin/softwareupdate"])
    }
}

@MainActor
@Suite("AppEnvironment Rosetta prompt")
struct AppEnvironmentRosettaTests {

    private func make(_ tmp: TempDir, runner: FakeProcessRunner, installed: Bool) -> AppEnvironment {
        AppEnvironment(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")), runner: runner,
                       updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()),
                       rosettaInstalled: { installed })
    }

    @Test("Rosetta present → no onboarding step, nothing to install")
    func present() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let env = make(tmp, runner: FakeProcessRunner(), installed: true)
        #expect(env.rosettaReady)
        #expect(!env.rosettaWasMissing)
    }

    @Test("Rosetta missing → install flips ready (even if the probe still disagrees) and keeps the step")
    func installSucceeds() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let runner = FakeProcessRunner()
        let env = make(tmp, runner: runner, installed: false)
        #expect(!env.rosettaReady && env.rosettaWasMissing)

        await env.installRosetta()
        #expect(env.rosettaReady)                  // fail-open: a successful install is trusted over the probe
        #expect(env.rosettaWasMissing)             // the step stays on screen, ticked
        #expect(env.rosettaMessage == nil)
        #expect(runner.invocations.map(\.executable.path) == ["/usr/sbin/softwareupdate"])
    }

    @Test("A failed install stays not-ready and surfaces the reason")
    func installFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let runner = FakeProcessRunner()
        runner.queueResult(ProcessResult(exitCode: 1, standardError: Data("No network".utf8)))
        let env = make(tmp, runner: runner, installed: false)

        await env.installRosetta()
        #expect(!env.rosettaReady)
        #expect(env.rosettaMessage == "Couldn't install Rosetta 2: No network")
    }
}
