import Foundation

public struct ZmxSessionRecord: Equatable, Sendable {
    public let name: String
    public let clients: Int?

    public init(name: String, clients: Int?) {
        self.name = name
        self.clients = clients
    }
}

public enum ZmxListParser {
    public enum ParseError: Error, Equatable {
        case missingName
        case missingClients(String)
        case invalidClients(String)
    }

    public static func parse(_ output: String) throws -> [ZmxSessionRecord] {
        try output.split(whereSeparator: \.isNewline).map { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("→ ") { line.removeFirst(2) }
            var name: String?
            var clients: Int?
            var hasError = false
            for field in line.split(separator: "\t", omittingEmptySubsequences: false) {
                if field.hasPrefix("name=") {
                    name = String(field.dropFirst("name=".count))
                } else if field.hasPrefix("clients=") {
                    let raw = String(field.dropFirst("clients=".count))
                    guard let value = Int(raw), value >= 0 else { throw ParseError.invalidClients(raw) }
                    clients = value
                } else if field.hasPrefix("err=") {
                    hasError = true
                }
            }
            guard let name, !name.isEmpty else { throw ParseError.missingName }
            guard clients != nil || hasError else { throw ParseError.missingClients(name) }
            return ZmxSessionRecord(name: name, clients: clients)
        }
    }
}

public enum ZmxReapPolicy {
    /// Nil means the live inventory was incomplete and no reap is safe. Non-live launches do not claim any
    /// daemon, so they can ignore the inventory and remove every zero-client agterm session in the namespace.
    public static func namesToKill(sessions: [ZmxSessionRecord], live: Bool,
                                   knownNames: Set<String>?) -> [String]? {
        if live, knownNames == nil { return nil }
        let claimed = knownNames ?? []
        return sessions.compactMap { session in
            guard session.name.hasPrefix("agterm-"), session.clients == 0 else { return nil }
            guard !live || !claimed.contains(session.name) else { return nil }
            return session.name
        }
    }
}

public enum PaneIdentityInventory {
    public struct Upgrade: Sendable {
        public let identities: Set<UUID>
        public let changed: Bool
    }

    public static func upgrade(_ snapshot: inout Snapshot) -> Upgrade {
        var identities: Set<UUID> = []
        var changed = false
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                var session = snapshot.workspaces[workspaceIndex].sessions[sessionIndex]
                if session.paneIdentity == nil {
                    session.paneIdentity = UUID()
                    changed = true
                }
                if let paneIdentity = session.paneIdentity { identities.insert(paneIdentity) }
                let hasSplit = (session.isSplit ?? false) || (session.hasSplit ?? false)
                if hasSplit {
                    if session.splitPaneIdentity == nil {
                        session.splitPaneIdentity = UUID()
                        changed = true
                    }
                    if let splitPaneIdentity = session.splitPaneIdentity { identities.insert(splitPaneIdentity) }
                }
                snapshot.workspaces[workspaceIndex].sessions[sessionIndex] = session
            }
        }
        return Upgrade(identities: identities, changed: changed)
    }

    @MainActor public static func identities(in sessions: [Session]) -> [UUID] {
        sessions.flatMap { session in
            [session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 }
        }
    }
}
