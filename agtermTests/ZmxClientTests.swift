import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxClientTests: XCTestCase {
    func testLiveReapListsThenKillsOnlyUnclaimedZeroClientNames() {
        let known = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let orphan = "agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", timeout: 1.5) {
            invocations.append($0)
            if $0.arguments == ["list"] {
                return """
                name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1
                name=\(orphan)\tpid=2\tclients=0\tcreated=1
                name=agterm-attached\tpid=3\tclients=1\tcreated=1
                """
            }
            return ""
        }

        XCTAssertTrue(client.reap(knownPaneIdentities: [known], live: true))
        XCTAssertEqual(invocations.map(\.arguments), [["list"], ["kill", orphan, "--force"]])
        XCTAssertEqual(invocations.map(\.timeout), [1.5, 1.5])
        XCTAssertEqual(invocations[0].environment["ZMX_DIR"], "/tmp/zmx-dir")
        XCTAssertNil(invocations[0].environment["ZMX_SESSION"])
    }

    func testIncompleteLiveInventorySkipsEveryProcessInvocation() {
        var calls = 0
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            calls += 1
            return ""
        }

        XCTAssertTrue(client.reap(knownPaneIdentities: nil, live: true))
        XCTAssertEqual(calls, 0)
    }

    func testSemanticKillUsesFullPaneDaemonNames() {
        let pane = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        var arguments: [String] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            arguments = $0.arguments
            return ""
        }

        XCTAssertTrue(client.kill(paneIdentities: [pane]))
        XCTAssertEqual(arguments, ["kill", "agterm-abcdef0123456789abcdef0123456789", "--force"])
    }
}
