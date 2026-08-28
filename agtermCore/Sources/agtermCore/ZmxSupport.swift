import Foundation

/// Host-free validation and configuration for a zmx-backed terminal surface.
public enum ZmxSupport {
    public enum LaunchDisposition: Equatable, Sendable {
        case ordinary
        case wrapped(Configuration)
        case fallback

        public var consumesRestoreState: Bool { self == .ordinary }
        public var backedByZmx: Bool {
            guard case .wrapped = self else { return false }
            return true
        }
    }

    public struct Inputs: Sendable {
        public let zmxExecutablePath: String
        public let passwordDatabaseShell: String?
        public let resourcesDirectory: String?
        public let stateDirectory: String
        public let paneIdentity: UUID
        public let baseEnvironment: [String: String]
        public let inheritedZdotdir: String?

        public init(zmxExecutablePath: String, passwordDatabaseShell: String?, resourcesDirectory: String?,
                    stateDirectory: String, paneIdentity: UUID, baseEnvironment: [String: String],
                    inheritedZdotdir: String?) {
            self.zmxExecutablePath = zmxExecutablePath
            self.passwordDatabaseShell = passwordDatabaseShell
            self.resourcesDirectory = resourcesDirectory
            self.stateDirectory = stateDirectory
            self.paneIdentity = paneIdentity
            self.baseEnvironment = baseEnvironment
            self.inheritedZdotdir = inheritedZdotdir
        }
    }

    public struct Configuration: Equatable, Sendable {
        public let command: String
        public let environment: [String: String]
        public let daemonName: String
        public let socketDirectory: String
        public let paneID: String

        public init(command: String, environment: [String: String], daemonName: String,
                    socketDirectory: String, paneID: String) {
            self.command = command
            self.environment = environment
            self.daemonName = daemonName
            self.socketDirectory = socketDirectory
            self.paneID = paneID
        }
    }

    public enum Rejection: Error, Equatable, Sendable {
        case executablePathNotAbsolute
        case executableUnavailable
        case unsupportedLoginShell
        case missingZshIntegration
        case socketPathTooLong

        public var message: String {
            switch self {
            case .executablePathNotAbsolute: "the zmx executable path is not absolute"
            case .executableUnavailable: "the zmx executable is unavailable"
            case .unsupportedLoginShell: "the password-database login shell is not zsh"
            case .missingZshIntegration: "the bundled zsh integration is unavailable"
            case .socketPathTooLong: "the zmx socket path exceeds the macOS sun_path budget"
            }
        }
    }

    /// zmx derives the final socket as `ZMX_DIR + "/" + daemonName`. Darwin's 104-byte
    /// `sun_path` leaves 103 usable bytes after the terminating NUL.
    static let maximumSocketPathBytes = 103

    public static func configuration(for inputs: Inputs) -> Result<Configuration, Rejection> {
        guard (inputs.zmxExecutablePath as NSString).isAbsolutePath else {
            return .failure(.executablePathNotAbsolute)
        }
        let executable = URL(fileURLWithPath: inputs.zmxExecutablePath).standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.executableUnavailable)
        }
        guard let shell = inputs.passwordDatabaseShell, CommandRestore.basename(shell) == "zsh" else {
            return .failure(.unsupportedLoginShell)
        }
        guard let resources = inputs.resourcesDirectory else {
            return .failure(.missingZshIntegration)
        }
        let integrationDirectory = URL(fileURLWithPath: resources)
            .standardizedFileURL.appending(path: "shell-integration/zsh").path
        guard FileManager.default.fileExists(atPath: integrationDirectory + "/.zshenv") else {
            return .failure(.missingZshIntegration)
        }

        let daemonName = "agterm-" + compactUUID(inputs.paneIdentity)
        let socketDirectory = socketDirectory(forStateDirectory: inputs.stateDirectory)
        guard socketPathFits(directory: socketDirectory, daemonName: daemonName) else {
            return .failure(.socketPathTooLong)
        }

        let paneID = inputs.paneIdentity.uuidString
        var environment = inputs.baseEnvironment
        environment["AGTERM_PANE_ID"] = paneID
        environment["SHELL"] = shell
        environment["ZDOTDIR"] = integrationDirectory
        if let inheritedZdotdir = inputs.inheritedZdotdir {
            environment["GHOSTTY_ZSH_ZDOTDIR"] = inheritedZdotdir
        }
        environment["ZMX_DIR"] = socketDirectory
        environment["ZMX_NO_DETACH_KEY"] = "1"

        return .success(Configuration(
            command: CommandRestore.shellQuotedLine([executable, "attach", daemonName]),
            environment: environment,
            daemonName: daemonName,
            socketDirectory: socketDirectory,
            paneID: paneID
        ))
    }

    public static func launchDisposition(requested: RestoreMode, active: RestoreMode,
                                         configuration: Configuration?) -> LaunchDisposition {
        guard requested == .live else { return .ordinary }
        guard active == .live, let configuration else { return .fallback }
        return .wrapped(configuration)
    }

    public static func socketDirectory(forStateDirectory stateDirectory: String) -> String {
        let canonical = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return "/tmp/agterm-zmx-\(stableHash(canonical))"
    }

    static func socketPathFits(directory: String, daemonName: String) -> Bool {
        (directory + "/" + daemonName).utf8.count <= maximumSocketPathBytes
    }

    private static func compactUUID(_ id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
