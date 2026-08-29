import Foundation
import Testing
@testable import agtermCore

/// Dispatcher coverage for `restore.mode` and the zmx group, kept out of the general dispatcher suite
/// because these turn on policy and inventory state rather than on target resolution.
@MainActor
struct ControlDispatcherZmxTests {
    private func dispatch(_ request: ControlRequest, _ actions: MockControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test func restoreModeWithNoArgumentReadsRatherThanWrites() async throws {
        let actions = MockControlActions()
        actions.nextRestoreModeResponse = ControlResponse(
            ok: true,
            result: ControlResult(restore: ControlRestoreStatus(configured: .live, requestedAtLaunch: .rerun,
                                                                active: .rerun, unavailableReason: nil)))

        let response = try #require(await dispatch(ControlRequest(cmd: .restoreMode), actions))
        #expect(response.ok)
        #expect(actions.calls == [.restoreModeRead])

        let status = try #require(response.result?.restore)
        #expect(status.configured == "live")
        #expect(status.requestedAtLaunch == "rerun")
        #expect(status.active == "rerun")
        #expect(status.restartRequired)
    }

    @Test(arguments: [RestoreMode.none, .rerun, .live])
    func restoreModeSetsEachKnownMode(mode: RestoreMode) async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: mode.rawValue))

        let response = try #require(await dispatch(request, actions))
        #expect(response.ok)
        #expect(actions.calls == [.restoreModeSet(mode)])
    }

    @Test func restoreModeRefusesAModeItDoesNotKnow() async throws {
        let actions = MockControlActions()
        let request = ControlRequest(cmd: .restoreMode, args: ControlArgs(mode: "sideways"))

        let response = try #require(await dispatch(request, actions))
        #expect(!response.ok)
        #expect(response.error?.contains("sideways") == true)
        // RestoreMode's own decoder would take this to `none`, whose next launch reaps every daemon
        #expect(actions.calls.isEmpty)
    }

    @Test func zmxListRoutesWithNoArgumentsToParse() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxList), actions))
        #expect(response.ok)
        #expect(actions.calls == [.zmxList])
    }

    @Test func zmxPruneRoutesWithNoArgumentsToParse() async throws {
        let actions = MockControlActions()
        let response = try #require(await dispatch(ControlRequest(cmd: .zmxPrune), actions))
        #expect(response.ok)
        #expect(actions.calls == [.zmxPrune])
    }

    @Test(arguments: [Command.zmxList, .zmxPrune])
    func zmxCommandsKeepTheirWireNames(command: Command) throws {
        let request = ControlRequest(cmd: command)
        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["cmd"] as? String == command.rawValue)
        #expect(command.rawValue.hasPrefix("zmx."))

        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.cmd == command)
    }

    @Test func zmxInventoryRoundTripsEveryRowKind() throws {
        let pane = UUID()
        let claim = ZmxPaneClaim(paneIdentity: pane, pane: .right, pendingClose: true, windowID: UUID(),
                                 windowName: nil, windowState: .unindexed, workspaceID: UUID(),
                                 workspaceName: "workspace 1", sessionID: UUID(), sessionName: "build")
        let result = ZmxInventory.join(
            observed: [ZmxSessionRecord(name: ZmxSupport.daemonName(for: pane), clients: 2, leaderPID: 9),
                       ZmxSessionRecord(name: "notes", clients: 0, leaderPID: 7)],
            claims: [claim], inventoryComplete: false)
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)

        let payload = ControlZmxInventory(restore: status, result: result)
        let decoded = try JSONDecoder().decode(ControlZmxInventory.self, from: JSONEncoder().encode(payload))

        #expect(decoded == payload)
        #expect(!decoded.inventoryComplete)
        let claimed = try #require(decoded.entries.first { $0.state == "pendingClose" })
        #expect(claimed.observation == "running")
        #expect(claimed.clients == 2)
        #expect(claimed.pane == "right")
        #expect(claimed.windowName == nil)
        #expect(claimed.windowState == "unindexed")
        #expect(claimed.sessionName == "build")

        let foreign = try #require(decoded.entries.first { $0.daemon == "notes" })
        #expect(foreign.state == "foreign")
        #expect(foreign.sessionID == nil)
    }

    @Test func restoreStatusHidesAProbedReasonUnlessLiveActuallyFellBack() {
        let asked = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .none,
                                         unavailableReason: "the password-database login shell is not zsh")
        #expect(asked.unavailableReason != nil)
        #expect(asked.active == "none")

        let neverAsked = ControlRestoreStatus(configured: .rerun, requestedAtLaunch: .rerun, active: .rerun,
                                              unavailableReason: "the password-database login shell is not zsh")
        #expect(neverAsked.unavailableReason == nil)
        #expect(!neverAsked.restartRequired)
    }

    @Test(arguments: [nil, "live"])
    func restoreModeRequestsSurviveTheWire(mode: String?) throws {
        let request = ControlRequest(cmd: .restoreMode, args: mode.map { ControlArgs(mode: $0) })
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded.cmd == .restoreMode)
        #expect(decoded.args?.mode == mode)

        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["cmd"] as? String == "restore.mode")
    }

    @Test func theWholeResponseCarriesTheStatusAndKeepsAFutureModeIntact() throws {
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)
        let response = ControlResponse(ok: true, result: ControlResult(restore: status))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.result?.restore == status)

        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        let restore = try #require(result["restore"] as? [String: Any])
        #expect(restore["configured"] as? String == "live")
        #expect(restore["unavailableReason"] == nil, "an absent reason must be omitted, not null")

        // a future server's mode must reach a stale CLI intact, nested where a caller actually reads it,
        // rather than collapsing to `none` the way RestoreMode's own lossy decoder would
        let future = Data("""
        {"ok":true,"result":{"restore":{"configured":"mirrored","requestedAtLaunch":"live",\
        "active":"live","restartRequired":true}}}
        """.utf8)
        let fromFuture = try JSONDecoder().decode(ControlResponse.self, from: future)
        #expect(fromFuture.result?.restore?.configured == "mirrored")
    }

    @Test func theUnsupportedRefusalNamesTheCommand() {
        // agtermCore is a library the agterm-linux fork consumes, so every Mac-only ControlActions
        // requirement ships a default returning this rather than breaking that build
        #expect(ControlActionsUnsupported.message("zmx.list") == "zmx.list is not supported on this platform")
    }
}
