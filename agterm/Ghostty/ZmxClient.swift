import agtermCore
import Darwin
import Foundation
import os

@MainActor
final class ZmxClient {
    struct Invocation {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
    }

    enum CommandError: Error {
        case timedOut
        case failed(Int32, String)
    }

    typealias Runner = (Invocation) throws -> String

    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxClient")
    private let executablePath: String
    private let socketDirectory: String
    private let timeout: TimeInterval
    private let runner: Runner

    init(executablePath: String, socketDirectory: String, timeout: TimeInterval = 3,
         runner: @escaping Runner = ZmxClient.run) {
        self.executablePath = executablePath
        self.socketDirectory = socketDirectory
        self.timeout = timeout
        self.runner = runner
    }

    @discardableResult
    func reap(knownPaneIdentities: Set<UUID>?, launchDecision: RestoreLaunchDecision) -> Bool {
        let requestedMode = launchDecision.requested
        if requestedMode == .live, knownPaneIdentities == nil {
            Self.logger.error("skipping live zmx reap because the persisted pane inventory is incomplete")
            return true
        }
        let output: String
        do {
            output = try invoke(["list"])
        } catch {
            Self.logger.error("zmx list failed during launch reap: \(String(describing: error), privacy: .public)")
            return false
        }
        let sessions: [ZmxSessionRecord]
        do {
            sessions = try ZmxListParser.parse(output)
        } catch {
            Self.logger.error("zmx list output was incomplete: \(String(describing: error), privacy: .public)")
            return false
        }
        let knownNames = knownPaneIdentities.map { Set($0.map(ZmxSupport.daemonName(for:))) }
        guard let names = ZmxReapPolicy.namesToKill(
            sessions: sessions, requestedMode: requestedMode, knownNames: knownNames) else {
            return true
        }
        return kill(names: names)
    }

    @discardableResult
    func kill(paneIdentities: [UUID]) -> Bool {
        kill(names: paneIdentities.map(ZmxSupport.daemonName(for:)))
    }

    /// The parsed listing behind `zmx list`. Nil when the listing could not be read or parsed, which is
    /// not the same answer as an empty namespace: no daemons at all is a successful empty result, while a
    /// failure must not read as "nothing to see" and let a caller act on that silence.
    func listSessions() -> [ZmxSessionRecord]? {
        do {
            return try ZmxListParser.parse(invoke(["list"]))
        } catch {
            Self.logger.error("zmx list failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func sessionLeaderPIDs() -> [String: pid_t]? {
        do {
            return ZmxLeaderMap.leaders(in: try ZmxListParser.parse(invoke(["list"])))
        } catch {
            Self.logger.error("zmx leader refresh failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// What a single unforced kill actually did. `staleSocket` is its own case because zmx prints
    /// `cleaned up stale session` and exits ZERO after merely unlinking a socket it could not connect to —
    /// the daemon may still be running, unreachable by name, so counting that as a kill would report a
    /// process gone that is not.
    enum KillOutcome: Equatable {
        case killed
        case staleSocket
        case failed(String)
    }

    /// Kills daemons the caller's listing observed as unclaimed and detached, one invocation each so the
    /// result can be reported per name.
    ///
    /// Never passes `--force`. Pinned zmx has no kill-if-detached, so this does NOT recheck the client
    /// count — the caller must re-list immediately before calling. What `--force` would add is the
    /// stale-socket unlink above, which is exactly the outcome that cannot be distinguished from success.
    func killObservedOrphan(names: [String]) -> [String: KillOutcome] {
        var outcomes: [String: KillOutcome] = [:]
        for name in Set(names) {
            do {
                let output = try invoke(["kill", name])
                outcomes[name] = output.contains("killed session \(name)") ? .killed : .staleSocket
            } catch {
                Self.logger.error("zmx kill failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                outcomes[name] = .failed(String(describing: error))
            }
        }
        return outcomes
    }

    private func kill(names: [String]) -> Bool {
        var seen: Set<String> = []
        let unique = names.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return true }
        do {
            _ = try invoke(["kill"] + unique + ["--force"])
            return true
        } catch {
            Self.logger.error("zmx kill failed for \(unique.joined(separator: ","), privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func invoke(_ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = socketDirectory
        environment.removeValue(forKey: "ZMX_SESSION")
        environment.removeValue(forKey: "ZMX_SESSION_PREFIX")
        return try runner(Invocation(executablePath: executablePath, arguments: arguments,
                                     environment: environment, timeout: timeout))
    }

    private nonisolated static func run(_ invocation: Invocation) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + invocation.timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            throw CommandError.timedOut
        }
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(process.terminationStatus, stdout + stderr)
        }
        return stdout
    }
}
