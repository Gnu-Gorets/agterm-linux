import Foundation
import Testing
@testable import agtermCore

struct RestoreModeTests {
    @Test(arguments: [
        (#""none""#, RestoreMode.none),
        (#""rerun""#, RestoreMode.rerun),
        (#""live""#, RestoreMode.live),
        (#""future""#, RestoreMode.none),
    ])
    func decodeIsLossy(raw: String, expected: RestoreMode) throws {
        #expect(try JSONDecoder().decode(RestoreMode.self, from: Data(raw.utf8)) == expected)
    }

    @Test func roundTrip() throws {
        for mode in RestoreMode.allCases {
            #expect(try JSONDecoder().decode(RestoreMode.self, from: JSONEncoder().encode(mode)) == mode)
        }
    }

    @Test func settingsNames() {
        #expect(RestoreMode.allCases.map(\.displayName) == ["Fresh shells", "Re-run commands", "Live sessions"])
    }

    @Test func liveFallsBackForAnUnsupportedPasswordDatabaseShell() {
        let decision = RestoreMode.live.launchDecision(passwordDatabaseShell: "/bin/bash")

        #expect(decision.requested == .live)
        #expect(decision.active == .none)
        #expect(decision.liveUnavailableReason ==
            "Live sessions require zsh as the macOS login shell; current shell is bash.")
    }

    @Test func supportedModesStayActive() {
        #expect(RestoreMode.live.launchDecision(passwordDatabaseShell: "/bin/zsh").active == .live)
        #expect(RestoreMode.rerun.launchDecision(passwordDatabaseShell: "/bin/bash").active == .rerun)
        #expect(RestoreMode.none.launchDecision(passwordDatabaseShell: nil).active == .none)
    }

    @Test func unsupportedShellReasonExistsBeforeLiveIsSelected() {
        let decision = RestoreMode.none.launchDecision(passwordDatabaseShell: "/bin/bash")

        #expect(decision.active == .none)
        #expect(decision.liveUnavailableReason ==
            "Live sessions require zsh as the macOS login shell; current shell is bash.")
    }
}
