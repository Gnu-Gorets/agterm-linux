import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxClientTests: XCTestCase {
    func testListSessionsInvokesOnlyListInTheInstanceNamespace() throws {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", timeout: 1.5) {
            invocations.append($0)
            return """
            name=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tpid=1\tclients=0\tcreated=1
            name=agterm-busy\terr=Timeout\tstatus=unreachable
            """
        }

        let records = try XCTUnwrap(client.listSessions())

        XCTAssertEqual(invocations.map(\.arguments), [["list"]], "the read must mutate nothing")
        XCTAssertEqual(invocations.first?.environment["ZMX_DIR"], "/tmp/zmx-dir")
        XCTAssertNil(invocations.first?.environment["ZMX_SESSION"],
                     "the app must not inherit a pane's own session into its listing")
        XCTAssertEqual(records.map(\.name), ["agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "agterm-busy"])
        XCTAssertEqual(records.first?.clients, 0)
        XCTAssertNil(records.last?.clients, "an err= row keeps its unreadable client count")
    }

    func testListSessionsReturnsEmptyForAnEmptyNamespaceAndNilOnFailure() {
        let empty = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in "" }
        XCTAssertEqual(empty.listSessions(), [], "no daemons is an answer, not a failure")

        let broken = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            throw ZmxClient.CommandError.timedOut
        }
        XCTAssertNil(broken.listSessions(), "a failed invocation must not read as an empty namespace")

        let garbled = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { _ in
            "pid=10\tclients=0\n"
        }
        XCTAssertNil(garbled.listSessions(), "an unparseable line must not read as an empty namespace")
    }

    func testKillObservedOrphanNeverForcesAndSeparatesAStaleSocketFromAKill() {
        var invocations: [[String]] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") { invocation in
            invocations.append(invocation.arguments)
            return invocation.arguments.contains("agterm-gone")
                ? "cleaned up stale session agterm-gone\n"
                : "killed session agterm-live\n"
        }

        let outcomes = client.killObservedOrphan(names: ["agterm-live", "agterm-gone"])

        XCTAssertEqual(outcomes["agterm-live"], .killed)
        XCTAssertEqual(outcomes["agterm-gone"], .staleSocket,
                       "an unlinked socket may leave the daemon running, so it is not a kill")
        XCTAssertEqual(Set(invocations), [["kill", "agterm-live"], ["kill", "agterm-gone"]])
        XCTAssertFalse(invocations.contains { $0.contains("--force") },
                       "--force would unlink a live daemon's socket and still exit zero")
    }

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

        XCTAssertTrue(client.reap(
            knownPaneIdentities: [known],
            launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil)))
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

        XCTAssertTrue(client.reap(
            knownPaneIdentities: nil,
            launchDecision: RestoreMode.live.launchDecision(liveUnavailableReason: nil)))
        XCTAssertEqual(calls, 0)
    }

    func testRequestedLiveFallbackPreservesClaimedDaemons() {
        let known = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var invocations: [[String]] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0.arguments)
            return "name=\(ZmxSupport.daemonName(for: known))\tpid=1\tclients=0\tcreated=1"
        }

        let fallback = RestoreMode.live.launchDecision(liveUnavailableReason: "login shell is not zsh")
        XCTAssertEqual(fallback.active, .none)
        XCTAssertTrue(client.reap(knownPaneIdentities: [known], launchDecision: fallback))
        XCTAssertEqual(invocations, [["list"]])
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

    func testLeaderRefreshUsesOneFullListingAndParsesOnlyAppSessions() {
        var invocations: [ZmxClient.Invocation] = []
        let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir") {
            invocations.append($0)
            return """
            name=agterm-a\tpid=10\tclients=1\tcreated=1
            name=other\tpid=11\tclients=0\tcreated=1
            """
        }

        XCTAssertEqual(client.sessionLeaderPIDs(), ["agterm-a": 10])
        XCTAssertEqual(invocations.map(\.arguments), [["list"]])
    }
}
