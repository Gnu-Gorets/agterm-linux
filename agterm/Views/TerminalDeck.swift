import SwiftUI

/// Terminal hosts fill the available area; their intrinsic sizes must not size the window.
struct TerminalDeck<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ZStack { content }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
