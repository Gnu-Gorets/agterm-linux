import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the zmx group's app arms: the join against the live claim walk, and the refusals
/// that must not read as an empty inventory.
@MainActor
final class ControlServerZmxTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-zmx-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    func testListJoinsObservedDaemonsAgainstTheLivePanes() throws {
        let live = try XCTUnwrap(library.allOpenSessions().first)
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let server = makeServer(list: """
        name=\(ZmxSupport.daemonName(for: live.paneIdentity))\tpid=1\tclients=1\tcreated=1
        name=\(orphan)\tpid=2\tclients=0\tcreated=1
        name=notes\tpid=3\tclients=0\tcreated=1
        """)

        let response = server.listZmxDaemons()

        XCTAssertTrue(response.ok)
        let inventory = try XCTUnwrap(response.result?.zmx)
        XCTAssertTrue(inventory.inventoryComplete)
        XCTAssertEqual(inventory.restore.active, GhosttyApp.shared.launchRestoreMode.rawValue)

        let claimed = try XCTUnwrap(inventory.entries.first { $0.sessionID == live.id.uuidString })
        XCTAssertEqual(claimed.state, "claimed")
        XCTAssertEqual(claimed.clients, 1)
        XCTAssertEqual(claimed.pane, "left")

        XCTAssertEqual(inventory.entries.first { $0.daemon == orphan }?.state, "orphan")
        XCTAssertEqual(inventory.entries.first { $0.daemon == "notes" }?.state, "foreign")
    }

    func testAnEmptyNamespaceIsASuccessfulEmptyInventory() throws {
        let response = makeServer(list: "").listZmxDaemons()

        XCTAssertTrue(response.ok, "no daemons is an answer, not a failure")
        let inventory = try XCTUnwrap(response.result?.zmx)
        XCTAssertTrue(inventory.entries.allSatisfy { $0.observation == "absent" },
                      "only the panes' own claims remain, each with no daemon behind it")
    }

    func testAFailedListingIsAnErrorRatherThanAnEmptyInventory() {
        let response = makeServer(list: nil).listZmxDaemons()

        XCTAssertFalse(response.ok, "not having looked must not read as nothing to see")
        XCTAssertEqual(response.error, "could not read the zmx session list")
        XCTAssertNil(response.result?.zmx)
    }

    func testWithoutAClientTheCommandSaysZmxIsUnavailable() {
        let server = ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)

        let response = server.listZmxDaemons()
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, ControlZmxError.unavailable)
    }

    /// A client whose runner returns `list` output, or throws when it is nil.
    private func makeServer(list output: String?) -> ControlServer {
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            guard let output else { throw ZmxClient.CommandError.timedOut }
            return output
        }
        return ControlServer(
            library: library, actions: AppActions(library: library), settingsModel: settingsModel,
            identity: AppIdentity(version: "9.9.9", commit: "testsha"),
            zmxClient: client,
            socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}
