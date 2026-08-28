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
    func reap(knownPaneIdentities: Set<UUID>?, live: Bool) -> Bool {
        if live, knownPaneIdentities == nil {
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
        guard let names = ZmxReapPolicy.namesToKill(sessions: sessions, live: live, knownNames: knownNames) else {
            return true
        }
        return kill(names: names)
    }

    @discardableResult
    func kill(paneIdentities: [UUID]) -> Bool {
        kill(names: paneIdentities.map(ZmxSupport.daemonName(for:)))
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
