import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ZmxLaunchTests: XCTestCase {
    func testLaunchDispositionKeepsFallbackStateUnconsumed() {
        let configuration = ZmxSupport.Configuration(
            command: "zmx attach session", environment: [:], daemonName: "session",
            socketDirectory: "/tmp/zmx", paneID: "pane")

        XCTAssertEqual(ZmxLaunch.disposition(requested: .rerun, active: .rerun,
                                             configuration: configuration), .ordinary)
        XCTAssertTrue(ZmxLaunch.Disposition.ordinary.consumesRestoreState)
        XCTAssertEqual(ZmxLaunch.disposition(requested: .live, active: .live,
                                             configuration: configuration), .wrapped(configuration))
        XCTAssertFalse(ZmxLaunch.Disposition.wrapped(configuration).consumesRestoreState)
        XCTAssertEqual(ZmxLaunch.disposition(requested: .live, active: .none,
                                             configuration: nil), .fallback)
        XCTAssertFalse(ZmxLaunch.Disposition.fallback.consumesRestoreState)
    }

    func testExecutablePathUsesOnlyDebugOverride() {
        let bundle = URL(fileURLWithPath: "/Applications/agterm.app", isDirectory: true)
        let environment = ["AGTERM_ZMX_PATH": "/tmp/debug-zmx"]

        XCTAssertEqual(ZmxLaunch.executablePath(bundleURL: bundle, environment: environment,
                                                allowDebugOverride: true), "/tmp/debug-zmx")
        XCTAssertEqual(ZmxLaunch.executablePath(bundleURL: bundle, environment: environment,
                                                allowDebugOverride: false),
                       "/Applications/agterm.app/Contents/MacOS/zmx")
    }

    func testDefaultUITestLaunchIsBypassedAndExplicitOptInUsesRealInputs() throws {
        let bundle = try makeBundleWithZshLoader()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let base = ["AGTERM_ZMX_PATH": "/bin/echo"]

        XCTAssertEqual(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle, environment: base, passwordDatabaseShell: "/bin/zsh",
            isUITestLaunch: true, allowDebugOverride: true), ZmxLaunch.uiTestBypassReason)
        var optedIn = base
        optedIn[ZmxLaunch.uiTestOptInKey] = "1"
        XCTAssertNil(ZmxLaunch.liveUnavailableReason(
            bundleURL: bundle, environment: optedIn, passwordDatabaseShell: "/bin/zsh",
            isUITestLaunch: true, allowDebugOverride: true))
    }

    func testWrappedStateIsFixedAtInitialization() {
        let view = GhosttySurfaceView(workingDirectory: "/tmp", backedByZmx: true)

        XCTAssertTrue(view.backedByZmx)
        XCTAssertTrue(view.isZmxWrapped)
    }

    private func makeBundleWithZshLoader() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-zmx-bundle-\(UUID().uuidString).app", isDirectory: true)
        let loader = bundle.appendingPathComponent("Contents/Resources/ghostty/shell-integration/zsh",
                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: loader, withIntermediateDirectories: true)
        try Data().write(to: loader.appendingPathComponent(".zshenv"))
        return bundle
    }
}
