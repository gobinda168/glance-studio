import GlanceCore
import GlanceKit
import SwiftUI

/// A card's newest capture, 72 x 45 (the replica's `.cx-thumb`). Both kinds are decoded on the gates' threads of their
/// own, a few at a time, never on the cooperative pool: a long board asks for many at once. A capture whose media was
/// cleared shows the plain chip block.
struct BoardThumbnail: View {
    let session: String
    let capture: ProofCapture
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 2).resizable().scaledToFill() }
            else { StudioColors.chip }
        }
        .frame(width: 72, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(StudioColors.line3, lineWidth: 1))
        .task(id: session + capture.id) { image = await Self.load(session: session, capture: capture) }
        .accessibilityHidden(true)
    }

    private static func load(session: String, capture: ProofCapture) async -> CGImage? {
        let url = WorkStore().mediaFolder(session: session).appendingPathComponent(capture.file)
        switch capture.kind {
        case .clip, .explainer:
            return await VideoThumbnail.image(of: url, maxSide: 144)
        case .screenshot, .file:
            return await PictureThumbnail.image(of: url, maxPixel: 144)
        }
    }
}
