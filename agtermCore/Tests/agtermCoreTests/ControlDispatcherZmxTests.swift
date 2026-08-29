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

    @Test func restoreStatusTravelsAsRawStringsSoAFutureModeSurvives() throws {
        let status = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live,
                                          unavailableReason: nil)
        let data = try JSONEncoder().encode(status)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["configured"] as? String == "live")

        // a future server's mode must reach a stale CLI intact rather than decoding to `none`
        let future = Data(#"{"configured":"mirrored","requestedAtLaunch":"live","active":"live","restartRequired":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ControlRestoreStatus.self, from: future)
        #expect(decoded.configured == "mirrored")
        #expect(decoded.unavailableReason == nil)
    }
}
