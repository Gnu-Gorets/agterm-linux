import agtermCore
import Darwin
import Foundation
import os

/// Debug-only process adapter around the host-free zmx configuration policy.
enum ZmxSpike {
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxSpike")

    @MainActor
    static func configuration(paneIdentity: UUID, environment base: [String: String]) -> ZmxSupport.Configuration? {
        let processEnv = ProcessInfo.processInfo.environment
        guard let rawPath = processEnv["AGTERM_ZMX_PATH"], !rawPath.isEmpty else { return nil }
        let inputs = ZmxSupport.Inputs(
            zmxExecutablePath: rawPath,
            passwordDatabaseShell: passwordDatabaseLoginShell(),
            resourcesDirectory: processEnv["GHOSTTY_RESOURCES_DIR"],
            stateDirectory: processEnv["AGTERM_STATE_DIR"] ?? PersistenceStore.defaultDirectory.path,
            paneIdentity: paneIdentity,
            baseEnvironment: base,
            inheritedZdotdir: processEnv["ZDOTDIR"]
        )
        return switch ZmxSupport.configuration(for: inputs) {
        case let .success(configuration): configuration
        case let .failure(reason): bypass(reason.message)
        }
    }

    static func passwordDatabaseLoginShell() -> String? {
        guard let entry = getpwuid(getuid()), let ptr = entry.pointee.pw_shell else { return nil }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

    @MainActor
    private static func bypass(_ reason: String) -> ZmxSupport.Configuration? {
        logger.warning("zmx spike bypassed: \(reason, privacy: .public)")
        return nil
    }
}
