import Foundation
import Darwin

/// Rosetta 2 — the translator every Silo runtime needs. CrossOver's Wine (and so the whole wine tree, DXMT
/// and DXVK) is x86_64 Mach-O; on Apple Silicon it only runs through Rosetta. macOS does not ship Rosetta
/// preinstalled, and a clean macOS 27 install has none — every `wine` spawn then fails with `EBADARCH`
/// ("Bad CPU type in executable", issue #7).
public enum Rosetta {
    /// Files only Rosetta's installer package (`com.apple.pkg.RosettaUpdateAuto`) lays down. macOS 27 moved
    /// the daemon onto the sealed system volume (`/usr/libexec/rosetta/oahd`, present even WITHOUT Rosetta),
    /// so the long-standing `/Library/Apple/usr/libexec/oahd` probe no longer exists there — the runtime
    /// payload under `oah/` is what the install adds on every release. Either one means installed.
    static let markerPaths = ["/Library/Apple/usr/libexec/oah/libRosettaRuntime",
                              "/Library/Apple/usr/libexec/oahd"]
    static let softwareUpdate = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
    static let installArguments = ["--install-rosetta", "--agree-to-license"]

    public enum RosettaError: LocalizedError, Equatable {
        /// An x86_64 binary was refused by the kernel (`EBADARCH`).
        case notInstalled
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Rosetta 2 isn't installed."
            case .installFailed(let detail): return "Couldn't install Rosetta 2: \(detail)"
            }
        }
    }

    /// Whether Rosetta is available. Intel Macs run the runtimes natively, so it's trivially true there. A
    /// false negative only costs an idempotent `install`, so the probe errs toward "missing".
    public static func isInstalled(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        #if arch(arm64)
        return markerPaths.contains(where: fileExists)
        #else
        return true
        #endif
    }

    /// Install Rosetta via `softwareupdate` (no admin prompt needed). Idempotent: on a Mac that already has
    /// it, `softwareupdate` just reports so and exits 0.
    public static func install(runner: ProcessRunning) async throws {
        let result = try await runner.run(executable: softwareUpdate, arguments: installArguments,
                                          environment: [:], currentDirectory: nil)
        guard result.succeeded else {
            let output = [result.stderrString, result.stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            throw RosettaError.installFailed(output ?? "softwareupdate exited \(result.exitCode)")
        }
    }

    /// Translate the kernel's `EBADARCH` from a spawn into `.notInstalled`, so the user reads "Rosetta 2 isn't
    /// installed" instead of the opaque "Bad CPU type in executable". Anything else passes through unchanged.
    static func translating(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EBADARCH) { return RosettaError.notInstalled }
        return error
    }
}
