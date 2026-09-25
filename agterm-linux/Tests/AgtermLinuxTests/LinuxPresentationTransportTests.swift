import CGtk
import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux presentation transport")
struct LinuxPresentationTransportTests {
    @Test("a real child exchanges newline frames and closes after the last frame")
    @MainActor
    func childFrames() {
        var lines: [String] = []
        var closed: String?
        let transport = LinuxPresentationTransport()
        let link = transport.open(
            ["/bin/sh", "-c", "IFS= read -r line; printf '%s\\n' \"$line\"; exit 7"],
            onLine: { lines.append(String(decoding: $0, as: UTF8.self)) },
            onClose: { closed = $0 })
        link.send(Data("hello from GTK\n".utf8))
        let deadline = Date().addingTimeInterval(5)
        while closed == nil && Date() < deadline {
            while g_main_context_iteration(nil, 0) != 0 {}
            usleep(10_000)
        }
        #expect(lines == ["hello from GTK"])
        #expect(closed == "exit 7")
        link.stop()
    }
}
