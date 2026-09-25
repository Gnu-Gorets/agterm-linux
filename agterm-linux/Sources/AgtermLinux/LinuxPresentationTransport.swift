import Foundation
import Glibc
import agtermCore

/// Keeps the origin's presentation stream off GTK's main thread while delivering frames on it.
@MainActor
final class LinuxPresentationTransport: RemotePresentationTransport {
    func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
              onClose: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
        LinuxPresentationLink(argv: argv, onLine: onLine, onClose: onClose)
    }
}

@MainActor
private final class LinuxPresentationLink: RemotePresentationLink {
    private let process = Process()
    private let input = Pipe()
    private let wake = Pipe()
    private let logger = LinuxStructuredLogger(category: "RemotePresentation")
    private let onClose: @MainActor (String) -> Void
    private var closed = false
    private var outputEnded = false
    private var readersEnded = false
    private var exitReason: String?

    init(argv: [String], onLine: @escaping @MainActor (Data) -> Void,
         onClose: @escaping @MainActor (String) -> Void) {
        self.onClose = onClose
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        process.terminationHandler = { [weak self] finished in
            let reason = "exit \(finished.terminationStatus)"
            runOnMain { MainActor.assumeIsolated { self?.exited(reason) } }
        }
        do {
            try process.run()
        } catch {
            let reason = "could not run \(argv.first ?? "the bridge"): \(error.localizedDescription)"
            MainTimer.schedule(after: 0) { [weak self] in self?.finish(reason) }
            return
        }
        // One queued callback per permit keeps a busy GTK loop from growing without bound.
        let inbound = DispatchSemaphore(value: 64)
        Self.readLines(from: output.fileHandleForReading, wake: wake, deliver: { line in
            inbound.wait()
            runOnMain {
                MainActor.assumeIsolated { onLine(line) }
                inbound.signal()
            }
        }, ended: { [weak self] in
            runOnMain { MainActor.assumeIsolated { self?.outputDidEnd() } }
        })
        Self.readLines(from: errors.fileHandleForReading, wake: wake, deliver: { [logger] line in
            logger.notice("presentation bridge: \(String(decoding: line, as: UTF8.self))")
        }, ended: {})
    }

    func send(_ line: Data) {
        guard !closed else { return }
        let fd = input.fileHandleForWriting.fileDescriptor
        let written = line.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else {
            logger.notice("presentation bridge stopped taking input")
            stop()
            return
        }
    }

    func stop() {
        endReaders()
        if process.isRunning { process.terminate() }
    }

    private func exited(_ reason: String) {
        exitReason = reason
        if outputEnded { finish(reason); return }
        MainTimer.schedule(after: 2) { [weak self] in self?.finish(reason) }
    }

    private func outputDidEnd() {
        outputEnded = true
        if let exitReason { finish(exitReason) } else { stop() }
    }

    private func endReaders() {
        guard !readersEnded else { return }
        readersEnded = true
        try? wake.fileHandleForWriting.write(contentsOf: Data([0]))
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        endReaders()
        onClose(reason)
    }

    private nonisolated static func readLines(from handle: FileHandle, wake: Pipe,
                                              deliver: @escaping @Sendable (Data) -> Void,
                                              ended: @escaping @Sendable () -> Void) {
        let thread = Thread {
            let fd = handle.fileDescriptor
            var polled = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: wake.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            reading: while true {
                let ready = poll(&polled, 2, -1)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0, polled[1].revents == 0 else { break }
                let count = Glibc.read(fd, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: chunk[0..<count])
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    guard newline - buffer.startIndex <= PresentationCodec.maxFrameBytes else { break reading }
                    deliver(Data(buffer[buffer.startIndex..<newline]))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                guard buffer.count <= PresentationCodec.maxFrameBytes else { break }
            }
            try? handle.close()
            ended()
        }
        thread.name = "agterm.presentation.read"
        thread.start()
    }
}
