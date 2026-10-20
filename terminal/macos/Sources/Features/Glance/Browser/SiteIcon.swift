import GlanceCore
import SwiftUI

/// A site's icon on a card-coloured squircle, or `initial` (else the globe) when there's none yet.
struct SiteIcon: View {
    let url: URL?
    var initial: String?
    let size: CGFloat
    @ObservedObject private var favicons = Favicons.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let image = favicons.image(key: url.flatMap(BrowserURL.iconKey)) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
                    .frame(width: size, height: size)
                    .background(StudioColors.card)
            } else if let initial {
                Text(initial)
                    .font(.studio(size * 0.46, .bold))
                    .foregroundStyle(StudioColors.ink)
                    .frame(width: size, height: size)
                    .background(StudioColors.line2)
            } else {
                StudioIcon(.globe, size: size * 0.62)
                    .foregroundStyle(StudioColors.muted)
                    .frame(width: size, height: size)
                    .background(StudioColors.line2)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(StudioColors.line2, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
