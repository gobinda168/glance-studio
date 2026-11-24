import SwiftUI

/// A git branch wherever Glance shows one: its name in medium mono ink behind a coral branch mark, on a small neutral
/// chip with a hairline, so it stands out from the muted paths and captions around it. Neutral, not coral-filled: a
/// selected row is already coral-tinted, and the coral command chip means Claude.
public struct BranchChip: View {
  private let branch: String
  private let size: CGFloat
  private let truncation: Text.TruncationMode
  private let tooltip: String?

  /// `tooltip` replaces the branch's name when hovering, for a chip inside something with its own.
  public init(_ branch: String, size: CGFloat = 11, truncation: Text.TruncationMode = .tail, tooltip: String? = nil) {
    self.branch = branch
    self.size = size
    self.truncation = truncation
    self.tooltip = tooltip
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    HStack(spacing: 4) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: size - 1, weight: .semibold))
        .foregroundStyle(GlanceColor.coralInk)
      Text(branch)
        .font(GlanceFont.mono(size, .medium))
        .foregroundStyle(GlanceColor.ink)
        .truncationMode(truncation)
    }
    .lineLimit(1)
    .padding(.horizontal, 5)
    .padding(.vertical, 1.5)
    .background(shape.fill(Color.primary.opacity(0.07)))
    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("branch \(branch)")
    .help(tooltip ?? branch)
  }
}
