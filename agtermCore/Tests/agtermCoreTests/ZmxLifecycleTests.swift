import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ZmxLifecycleTests {
    @Test func listParserKeepsClientCountsAndUnreachableNames() throws {
        let output = """
        name=agterm-a\tpid=10\tclients=0\tcreated=1\tcwd=/tmp
        name=agterm-b\tpid=11\tclients=2\tcreated=1\tcmd=zsh
        name=agterm-busy\terr=Timeout\tstatus=unreachable

        """

        #expect(try ZmxListParser.parse(output) == [
            ZmxSessionRecord(name: "agterm-a", clients: 0),
            ZmxSessionRecord(name: "agterm-b", clients: 2),
            ZmxSessionRecord(name: "agterm-busy", clients: nil),
        ])
    }

    @Test func listParserRejectsPartialOutputInsteadOfReapingFromIt() {
        #expect((try? ZmxListParser.parse("")) == [])
        #expect(throws: ZmxListParser.ParseError.self) {
            try ZmxListParser.parse("pid=10\tclients=0\n")
        }
        #expect(throws: ZmxListParser.ParseError.self) {
            try ZmxListParser.parse("name=agterm-a\tclients=wat\n")
        }
    }

    @Test func reapPolicyUsesCompleteLiveInventoryAndZeroClientAppNamesOnly() {
        let sessions = [
            ZmxSessionRecord(name: "agterm-known", clients: 0),
            ZmxSessionRecord(name: "agterm-orphan", clients: 0),
            ZmxSessionRecord(name: "agterm-attached", clients: 1),
            ZmxSessionRecord(name: "other", clients: 0),
            ZmxSessionRecord(name: "agterm-busy", clients: nil),
        ]

        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, live: true,
                                          knownNames: ["agterm-known"]) == ["agterm-orphan"])
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, live: true, knownNames: nil) == nil)
        #expect(ZmxReapPolicy.namesToKill(sessions: sessions, live: false,
                                          knownNames: nil) == ["agterm-known", "agterm-orphan"])
    }

    @Test func immediateSessionAndWorkspaceCloseFinalizeEveryOwnedPane() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let firstWorkspace = store.addWorkspace(name: "first")
        let first = try #require(store.addSession(toWorkspace: firstWorkspace.id, cwd: "/first"))
        let firstSplit = UUID()
        first.hasSplit = true
        first.splitPaneIdentity = firstSplit
        let secondWorkspace = store.addWorkspace(name: "second")
        let second = try #require(store.addSession(toWorkspace: secondWorkspace.id, cwd: "/second"))

        store.closeSession(first.id)
        #expect(finalized == [[first.paneIdentity, firstSplit]])

        store.removeWorkspace(secondWorkspace.id)
        #expect(finalized == [[first.paneIdentity, firstSplit], [second.paneIdentity]])
    }

    @Test func undoKeepsPanesAndGraceFinalizationKillsThem() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let split = UUID()
        session.hasSplit = true
        session.splitPaneIdentity = split

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(finalized.isEmpty)
        #expect(store.undoPendingClose())
        #expect(finalized.isEmpty)

        #expect(store.softCloseSession(session.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(finalized == [[session.paneIdentity, split]])
    }

    @Test func workspaceGraceFinalizesAllPanesOnlyAfterTheUndoWindow() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        _ = store.addWorkspace(name: "kept")
        let removed = store.addWorkspace(name: "removed")
        let session = try #require(store.addSession(toWorkspace: removed.id, cwd: "/repo"))

        #expect(store.softRemoveWorkspace(removed.id, grace: 60))
        #expect(finalized.isEmpty)
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(finalized == [[session.paneIdentity]])
    }

    @Test func splitCloseFinalizesOnlySplitWhilePromotionMovesSurvivorIdentity() throws {
        var finalized: [[UUID]] = []
        let store = AppStore(persistence: temporaryPersistence(),
                             paneFinalizer: { finalized.append($0) })
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let split = UUID()
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = split

        store.closeSplit(session.id)
        #expect(finalized == [[split]])
        #expect(session.paneIdentity != split)

        finalized.removeAll()
        let promoted = UUID()
        session.surface = SpySurface()
        session.splitSurface = SpySurface()
        session.hasSplit = true
        session.isSplit = true
        session.splitPaneIdentity = promoted
        store.closePrimaryPane(session.id)
        #expect(finalized.isEmpty)
        #expect(session.paneIdentity == promoted)
        #expect(session.splitPaneIdentity == nil)
    }

    @Test func windowDeleteFinalizesOpenAndClosedWindowsWhileCloseAloneKeepsPanes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var finalized: [[UUID]] = []
        let library = WindowLibrary(directory: directory, paneFinalizer: { finalized.append($0) })
        let openExtra = library.newWindow(name: "open")
        let openSession = try #require(library.store(for: openExtra.id)?.workspaces.first?.sessions.first)
        library.removeWindow(openExtra.id)
        #expect(finalized == [[openSession.paneIdentity]])

        let closedExtra = library.newWindow(name: "closed")
        let closedSession = try #require(library.store(for: closedExtra.id)?.workspaces.first?.sessions.first)
        let closedIdentities = [closedSession.paneIdentity]

        library.closeWindow(closedExtra.id)
        #expect(finalized == [[openSession.paneIdentity]])
        library.removeWindow(closedExtra.id)
        #expect(finalized == [[openSession.paneIdentity], closedIdentities])
    }

    @Test func launchInventoryUpgradesLegacyPaneIdentitiesBeforeStoreRestore() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let windowID = UUID()
        try writeIndex(WindowsIndex(windows: [WindowEntry(id: windowID, name: "window 1", isOpen: true)]),
                       directory: directory)
        try writeWindow(Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "work", sessions: [
                SessionSnapshot(id: UUID(), customName: nil, cwd: "/repo", isSplit: true),
            ])]), id: windowID, directory: directory)
        var inventories: [Set<UUID>?] = []

        let library = WindowLibrary(directory: directory, paneFinalizer: nil,
                                    launchInventorySink: { inventories.append($0) })
        let restored = try #require(library.store(for: windowID)?.workspaces.first?.sessions.first)
        let disk = try PersistenceStore(
            directory: directory.appendingPathComponent("windows"),
            fileName: "\(windowID.uuidString).json").loadChecked()
        let persisted = try #require(disk.workspaces.first?.sessions.first)

        #expect(inventories == [Set([restored.paneIdentity, try #require(restored.splitPaneIdentity)])])
        #expect(persisted.paneIdentity == restored.paneIdentity)
        #expect(persisted.splitPaneIdentity == restored.splitPaneIdentity)
    }

    @Test func corruptClosedWindowMakesLaunchInventoryIncomplete() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = UUID(), closed = UUID()
        try writeIndex(WindowsIndex(windows: [
            WindowEntry(id: open, name: "open", isOpen: true),
            WindowEntry(id: closed, name: "closed", isOpen: false),
        ]), directory: directory)
        try writeWindow(Snapshot(workspaces: [WorkspaceSnapshot(
            id: UUID(), name: "work", sessions: [SessionSnapshot(id: UUID(), customName: nil, cwd: "/repo")])]),
                        id: open, directory: directory)
        let closedURL = directory.appendingPathComponent("windows/\(closed.uuidString).json")
        try Data("{".utf8).write(to: closedURL)
        var inventories: [Set<UUID>?] = []

        _ = WindowLibrary(directory: directory, paneFinalizer: nil,
                          launchInventorySink: { inventories.append($0) })
        #expect(inventories.count == 1)
        #expect(inventories[0] == nil)
    }

    @Test func snapshotRestoreKeepsTheDaemonNameForMissingDaemonUpsert() throws {
        let store = AppStore(persistence: temporaryPersistence())
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/repo"))
        let expected = ZmxSupport.daemonName(for: session.paneIdentity)
        let snapshot = store.snapshot()
        let restored = AppStore(persistence: temporaryPersistence())

        restored.restore(from: snapshot, launchRestore: true)
        let restoredSession = try #require(restored.workspaces.first?.sessions.first)
        #expect(ZmxSupport.daemonName(for: restoredSession.paneIdentity) == expected)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryPersistence() -> PersistenceStore {
        PersistenceStore(directory: temporaryDirectory())
    }

    private func writeIndex(_ index: WindowsIndex, directory: URL) throws {
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("windows.json"))
    }

    private func writeWindow(_ snapshot: Snapshot, id: UUID, directory: URL) throws {
        try PersistenceStore(directory: directory.appendingPathComponent("windows"),
                             fileName: "\(id.uuidString).json").save(snapshot)
    }
}
