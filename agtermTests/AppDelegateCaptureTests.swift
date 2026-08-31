import AppKit
import Darwin
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class AppDelegateCaptureTests: XCTestCase {
    func testLivePrimaryAndHiddenSplitUseOneFreshSnapshot() throws {
        let primaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let splitID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let session = Session(initialCwd: "/tmp", paneIdentity: primaryID, splitPaneIdentity: splitID)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": primaryID.uuidString], backedByZmx: true)
        let split = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": splitID.uuidString], backedByZmx: true)
        split.setPaneRole(.split)
        session.splitSurface = split
        session.hasSplit = true
        session.isSplit = false
        var timeout: TimeInterval?
        let resolver = ZmxForegroundResolver(
            leaderProvider: {
                timeout = $0
                return [ZmxSupport.daemonName(for: primaryID): 10, ZmxSupport.daemonName(for: splitID): 20]
            },
            leaderProbe: { .foreground($0 + 1) })

        let count = AppDelegate.captureForegroundCommands(
            sessions: [session], zmxResolver: resolver,
            commandReader: { view, _, snapshot in
                let name = try? XCTUnwrap(view.zmxSessionName)
                let pid = name.flatMap { snapshot?.foregroundPID(sessionName: $0) }
                return pid.map { ["worker", String($0)] }
            })

        XCTAssertEqual(count, 2)
        XCTAssertEqual(timeout, ZmxClient.captureInvocationTimeout)
        XCTAssertEqual(session.foregroundCommand, ["worker", "11"])
        XCTAssertEqual(session.splitForegroundCommand, ["worker", "21"])
    }

    func testHiddenNonLiveSplitStaysNilWhileShownNonLivePanesKeepTheOldPath() {
        let hidden = Session(initialCwd: "/tmp")
        hidden.splitSurface = GhosttySurfaceView(workingDirectory: "/tmp")
        hidden.hasSplit = true
        hidden.isSplit = false
        hidden.splitForegroundCommand = ["stale"]
        var hiddenReads = 0

        _ = AppDelegate.captureForegroundCommands(
            sessions: [hidden], commandReader: { _, _, _ in
                hiddenReads += 1
                return ["wrong"]
            })

        XCTAssertEqual(hiddenReads, 0)
        XCTAssertNil(hidden.splitForegroundCommand)

        let shown = Session(initialCwd: "/tmp")
        shown.surface = GhosttySurfaceView(workingDirectory: "/tmp")
        let split = GhosttySurfaceView(workingDirectory: "/tmp")
        split.setPaneRole(.split)
        shown.splitSurface = split
        shown.hasSplit = true
        shown.isSplit = true
        _ = AppDelegate.captureForegroundCommands(
            sessions: [shown], commandReader: { view, _, snapshot in
                XCTAssertNil(snapshot)
                return [view.isSplitPane ? "split" : "primary"]
            })

        XCTAssertEqual(shown.foregroundCommand, ["primary"])
        XCTAssertEqual(shown.splitForegroundCommand, ["split"])
    }

    func testFreshSnapshotFailureAndMidLoopExpiryNeverUseStaleLeaders() {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let first = liveSession(paneID: firstID)
        let second = liveSession(paneID: secondID)
        var fail = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: { _ in
                fail ? nil : [ZmxSupport.daemonName(for: firstID): 10,
                              ZmxSupport.daemonName(for: secondID): 20]
            },
            leaderProbe: { .foreground($0 + 1) })
        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        fail = true
        first.foregroundCommand = ["stale"]

        _ = AppDelegate.captureForegroundCommands(
            sessions: [first], zmxResolver: resolver,
            commandReader: { _, _, _ in XCTFail("failed refresh must not read a command"); return nil })

        XCTAssertNil(first.foregroundCommand)
        fail = false
        first.foregroundCommand = nil
        second.foregroundCommand = ["stale"]
        var checks = 0
        _ = AppDelegate.captureForegroundCommands(
            sessions: [first, second], zmxResolver: resolver,
            timeRemaining: {
                checks += 1
                return checks == 1
            },
            commandReader: { _, _, _ in ["captured"] })

        XCTAssertEqual(first.foregroundCommand, ["captured"])
        XCTAssertNil(second.foregroundCommand)
    }

    func testCapturePolicyIncludesLiveAndRerunButNotFreshShells() {
        XCTAssertTrue(GhosttyApp.capturesForegroundOnExit(mode: .live))
        XCTAssertTrue(GhosttyApp.capturesForegroundOnExit(mode: .rerun))
        XCTAssertFalse(GhosttyApp.capturesForegroundOnExit(mode: .none))
    }

    func testLastWindowClosePersistsInjectedCaptureBeforeTeardown() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-exit-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.activeSession)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WindowAccessor.TitleProbeView(
            windowID: windowID, library: library, store: store,
            captureOnExit: { sessions in
                sessions.first?.foregroundCommand = ["worker", "--live"]
                return 1
            })

        window.close()

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand, ["worker", "--live"])
    }

    func testApplicationTerminationPersistsInjectedCaptureBeforeSavingOpenWindows() throws {
        let state = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-terminate-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let library = WindowLibrary(directory: state)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let delegate = AppDelegate()
        delegate.library = library
        delegate.captureOnExit = { sessions in
            sessions.first?.foregroundCommand = ["worker", "--terminate"]
            return 1
        }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        let persisted = PersistenceStore(
            directory: state.appendingPathComponent("windows"), fileName: "\(windowID.uuidString).json").load()
        XCTAssertTrue(library.isTerminating)
        XCTAssertEqual(persisted.workspaces.first?.sessions.first?.foregroundCommand,
                       ["worker", "--terminate"])
    }

    private func liveSession(paneID: UUID) -> Session {
        let session = Session(initialCwd: "/tmp", paneIdentity: paneID)
        session.surface = GhosttySurfaceView(
            workingDirectory: "/tmp", env: ["AGTERM_PANE_ID": paneID.uuidString], backedByZmx: true)
        return session
    }
}
