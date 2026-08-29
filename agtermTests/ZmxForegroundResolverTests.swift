import Darwin
import XCTest
@testable import agterm

@MainActor
final class ZmxForegroundResolverTests: XCTestCase {
    func testOneRefreshServesMultiplePaneLookupsUntilLifecycleInvalidation() async {
        let fixture = LeaderFixture(leaders: ["agterm-a": 10, "agterm-b": 20])
        let resolver = ZmxForegroundResolver(
            leaderProvider: fixture.provide,
            leaderProbe: { .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        await waitUntil("initial leaders") {
            resolver.foregroundPID(sessionName: "agterm-a") == 11 &&
                resolver.foregroundPID(sessionName: "agterm-b") == 21
        }
        XCTAssertEqual(fixture.listings, 1)
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
        XCTAssertEqual(fixture.listings, 1)

        fixture.leaders = ["agterm-a": 30, "agterm-b": 20]
        resolver.noteLifecycleChange()
        resolver.refreshIfNeeded(now: start.addingTimeInterval(2))
        await waitUntil("invalidated leader") {
            resolver.foregroundPID(sessionName: "agterm-a") == 31
        }
        XCTAssertEqual(fixture.listings, 2)
    }

    func testFailedRefreshKeepsLiveCacheAndDeadLeaderIsEvicted() async {
        let fixture = LeaderFixture(leaders: ["agterm-a": 10])
        var dead = false
        let resolver = ZmxForegroundResolver(
            leaderProvider: fixture.provide,
            leaderProbe: { dead ? .dead : .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        await waitUntil("initial leader") {
            resolver.foregroundPID(sessionName: "agterm-a") == 11
        }
        fixture.fails = true
        resolver.noteLifecycleChange()
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
        await waitUntil("failed listing") { fixture.listings == 2 }
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)

        dead = true
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"))
        dead = false
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"), "dead entries stay evicted until refresh")
    }

    func testNoForegroundDoesNotEvictALiveLeader() async {
        let fixture = LeaderFixture(leaders: ["agterm-a": 10])
        var hasForeground = true
        let resolver = ZmxForegroundResolver(
            leaderProvider: fixture.provide,
            leaderProbe: { hasForeground ? .foreground($0 + 1) : .noForeground })

        resolver.refreshIfNeeded(now: Date(timeIntervalSince1970: 100))
        await waitUntil("initial leader") {
            resolver.foregroundPID(sessionName: "agterm-a") == 11
        }
        hasForeground = false
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-a"))
        hasForeground = true
        XCTAssertEqual(resolver.foregroundPID(sessionName: "agterm-a"), 11)
    }

    func testMissingNameWaitsForReconcileInsteadOfRefreshingEveryTree() async {
        let fixture = LeaderFixture(leaders: ["agterm-a": 10])
        let resolver = ZmxForegroundResolver(
            leaderProvider: fixture.provide,
            leaderProbe: { .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        await waitUntil("initial leader") {
            resolver.foregroundPID(sessionName: "agterm-a") == 11
        }
        XCTAssertNil(resolver.foregroundPID(sessionName: "agterm-missing"))
        resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.listings, 1)
    }

    func testFailedRefreshRetriesWithoutWaitingForReconcile() async {
        let fixture = LeaderFixture(leaders: ["agterm-a": 10], fails: true)
        let resolver = ZmxForegroundResolver(
            leaderProvider: fixture.provide,
            leaderProbe: { .foreground($0 + 1) })
        let start = Date(timeIntervalSince1970: 100)

        resolver.refreshIfNeeded(now: start)
        await waitUntil("failed listing") { fixture.listings == 1 }
        fixture.fails = false
        await waitUntil("retry") {
            resolver.refreshIfNeeded(now: start.addingTimeInterval(1))
            return resolver.foregroundPID(sessionName: "agterm-a") == 11
        }
        XCTAssertEqual(fixture.listings, 2)
    }

    func testRefreshDoesNotRunTheProviderOnTheMainActor() async {
        let fixture = LeaderFixture(leaders: [:], delay: 0.25)
        let resolver = ZmxForegroundResolver(leaderProvider: fixture.provide)
        let started = Date()

        resolver.refreshIfNeeded()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        await waitUntil("background listing") { fixture.listings == 1 }
    }

    private func waitUntil(_ description: String, predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }
}

private final class LeaderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLeaders: [String: pid_t]
    private var shouldFail: Bool
    private var count = 0
    private let delay: TimeInterval

    init(leaders: [String: pid_t], fails: Bool = false, delay: TimeInterval = 0) {
        storedLeaders = leaders
        shouldFail = fails
        self.delay = delay
    }

    var leaders: [String: pid_t] {
        get { withLock { storedLeaders } }
        set { withLock { storedLeaders = newValue } }
    }

    var fails: Bool {
        get { withLock { shouldFail } }
        set { withLock { shouldFail = newValue } }
    }

    var listings: Int { withLock { count } }

    func provide() -> [String: pid_t]? {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return withLock {
            count += 1
            return shouldFail ? nil : storedLeaders
        }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
