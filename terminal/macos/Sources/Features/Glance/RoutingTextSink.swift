import AppKit
import GlanceCore
import GlanceKit

/// The one dictation's sink: into the focused terminal split, or typed into the app in front, by `AppSurfaces`.
@MainActor
final class RoutingTextSink: TextSink {
    private let studio: SurfaceTextSink
    private let front = AccessibilityTextSink()

    init(studio: SurfaceTextSink) { self.studio = studio }

    private var route: AppSurfaces.DictationRoute {
        Prefs.surfaces.dictationRoute(appActive: NSApp.isActive, studioHasFocusedTerminal: studio.canInsert)
    }

    var canInsert: Bool {
        switch route {
        case .studioTerminal: return studio.canInsert
        case .frontApp: return front.canInsert
        case .none: return false
        }
    }

    var accessHint: String { route == .studioTerminal ? studio.accessHint : front.accessHint }

    func requestAccess() { front.requestAccess() }

    func insert(_ text: String) -> TextInserter.Outcome {
        switch route {
        case .studioTerminal: return studio.insert(text)
        case .frontApp: return front.insert(text)
        case .none: return .failed
        }
    }
}
