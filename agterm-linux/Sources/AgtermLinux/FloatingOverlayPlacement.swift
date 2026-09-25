import CGtk
import agtermCore

@MainActor
extension AppController {
    func floatingOverlayHost(for session: Session, pane: OverlayPane?) -> OpaquePointer {
        switch pane {
        case .left: return primaryPaneHosts[session.id] ?? deck
        case .right: return splitPaneHosts[session.id] ?? deck
        case nil: return deck
        }
    }

    func removeFloatingOverlayFrame(_ frame: OpaquePointer) {
        guard let parent = gtk_widget_get_parent(W(frame)) else { return }
        gtk_overlay_remove_overlay(OpaquePointer(parent), W(frame))
    }

    func placeFloatingOverlayFrame(_ frame: OpaquePointer, for session: Session) -> OpaquePointer {
        let host = floatingOverlayHost(for: session, pane: session.hudTargetPane)
        if let parent = gtk_widget_get_parent(W(frame)), OpaquePointer(parent) != host {
            // GTK containers own sunk children; hold the frame while moving it between pane hosts.
            g_object_ref(RAW(frame))
            gtk_overlay_remove_overlay(OpaquePointer(parent), W(frame))
            gtk_overlay_add_overlay(host, W(frame))
            g_object_unref(RAW(frame))
            return host
        }
        if gtk_widget_get_parent(W(frame)) == nil {
            gtk_overlay_add_overlay(host, W(frame))
        }
        return host
    }
}
