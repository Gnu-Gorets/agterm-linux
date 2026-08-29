import agtermCore
import Darwin
import Foundation
import os

/// Maps a wrapped pane's stable zmx name to the daemon-side pty foreground process group. One bounded
/// `zmx list` refresh populates every pane; per-pane lookups are a cached name lookup plus one sysctl.
@MainActor
final class ZmxForegroundResolver {
    enum LeaderProbe: Equatable {
        case foreground(pid_t)
        case noForeground
        case dead
    }

    typealias LeaderProvider = @Sendable () -> [String: pid_t]?
    typealias Probe = (pid_t) -> LeaderProbe

    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "ZmxForeground")
    private let leaderProvider: LeaderProvider
    private let leaderProbe: Probe
    private var leaders: [String: pid_t] = [:]
    private var refreshGate = ZmxRefreshGate()
    private var lifecycleRevision = 0
    private var refreshTask: Task<Void, Never>?

    init(leaderProvider: @escaping LeaderProvider, leaderProbe: @escaping Probe = ZmxForegroundResolver.probe) {
        self.leaderProvider = leaderProvider
        self.leaderProbe = leaderProbe
    }

    func noteLifecycleChange() {
        lifecycleRevision &+= 1
        refreshGate.noteLifecycleChange()
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard refreshTask == nil, refreshGate.shouldRefresh(now: now) else { return }
        let provider = leaderProvider
        let revision = lifecycleRevision
        refreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) { provider() }.value
            guard let self else { return }
            self.refreshTask = nil
            guard let refreshed else { return }
            self.leaders = refreshed
            if self.lifecycleRevision == revision { self.refreshGate.didRefresh(now: now) }
        }
    }

    func foregroundPID(sessionName: String) -> pid_t? {
        guard let leader = leaders[sessionName] else { return nil }
        switch leaderProbe(leader) {
        case .foreground(let pid): return pid
        case .noForeground: return nil
        case .dead:
            leaders[sessionName] = nil
            refreshGate.noteLifecycleChange()
            Self.logger.debug("evicted dead zmx leader \(leader, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func probe(_ leader: pid_t) -> LeaderProbe {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, leader]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == leader else { return .dead }
        let foreground = info.kp_eproc.e_tpgid
        return foreground > 0 ? .foreground(foreground) : .noForeground
    }
}
