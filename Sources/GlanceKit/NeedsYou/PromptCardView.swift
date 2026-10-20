import GlanceCore
import SwiftUI

/// A Claude Code prompt on the floating card panel: what is asked, what it's about, and its answers. A sibling of
/// `ChannelCardView` (same chrome); the answers are typed into the split by Studio.
struct PromptCardView: View {
  let prompt: PendingPrompt
  @ObservedObject var model: ChannelCardsModel
  let send: (String) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var fieldFocused: Bool

  private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

  private var title: String { prompt.screen.question ?? "Claude needs you" }
  private var screen: DialogScreen { prompt.screen }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Text(title)
        .font(GlanceFont.sans(13, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      details
      answers
      if let field = placeholder { textField(field) }
      if let notice = model.promptNotice {
        Text(notice).font(GlanceFont.sans(11)).foregroundStyle(GlanceColor.muted)
      }
      Text("or answer in the terminal")
        .font(GlanceFont.sans(11))
        .foregroundStyle(GlanceColor.muted)
    }
    .padding(14)
    .frame(width: ChannelCards.width, alignment: .leading)
    .modifier(CardSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(prompt.project) needs you: \(title)")
  }

  private var header: some View {
    HStack(spacing: 8) {
      NoticeGlyph(source: .claude, size: 13)
        .foregroundStyle(GlanceColor.ink)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
      Text("\(prompt.project) · \(NeedsYouRules.what(prompt))")
        .font(GlanceFont.sans(12, .medium))
        .foregroundStyle(GlanceColor.muted)
        .lineLimit(1)
      Spacer(minLength: 4)
      Button("Open") { NeedsYouCards.onOpen?(prompt) }
        .buttonStyle(.plain)
        .font(GlanceFont.sans(12))
        .foregroundStyle(GlanceColor.coralInk)
        .accessibilityLabel("Open \(prompt.project)")
      DismissButton(label: "Hide \(title)") { ChannelCards.shared.hide(prompt) }
    }
  }

  // MARK: Details

  @ViewBuilder private var details: some View {
    switch PromptDetails.of(prompt) {
    case .command(let text): block(text, maxHeight: 96)
    case .fields(let lines), .screen(let lines): block(lines.joined(separator: "\n"), maxHeight: 96)
    case .edit(let path, let added, let removed):
      HStack(spacing: 8) {
        Text(path)
          .font(GlanceFont.mono(11))
          .foregroundStyle(GlanceColor.body)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        Text("+\(added)").font(GlanceFont.mono(11)).foregroundStyle(GlanceColor.okInk)
        Text("−\(removed)").font(GlanceFont.mono(11)).foregroundStyle(GlanceColor.criticalInk)
      }
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    case .plan(let markdown):
      ScrollView {
        Text(LocalizedStringKey(markdown))
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(maxHeight: 180)
    case .none: EmptyView()
    }
  }

  private func block(_ text: String, maxHeight: CGFloat) -> some View {
    ScrollView {
      Text(text)
        .font(GlanceFont.mono(11))
        .foregroundStyle(GlanceColor.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .frame(maxHeight: maxHeight)
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
  }

  // MARK: Answers

  private var multi: Bool { screen.options.contains { $0.checked != nil } }
  private var rows: [PendingPrompt.Shown] { prompt.shownAnswers }

  private func short(_ label: String) -> String {
    label.components(separatedBy: " · ").first ?? label
  }

  private func hint(_ row: PendingPrompt.Shown) -> String? {
    if prompt.kind == .permission {
      if row.option.number == 1 { return "⌥Y" }
      if row.option.number == PromptKeys.denyNumber(screen) { return "⌥N" }
      return nil
    }
    return row.position < 4 ? "⌥\(row.position + 1)" : nil
  }

  @ViewBuilder private var answers: some View {
    let rows = rows
    let stacked = rows.count > 3 || rows.contains { short($0.option.label).count > 22 } || multi
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
    layout {
      ForEach(rows) { row in answerButton(row, first: row.position == 0) }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    if multi, PromptKeys.keys(.submit, kind: prompt.kind, screen: screen) != nil {
      HStack {
        Spacer(minLength: 0)
        GlanceButton("Submit", style: .primary, label: "Submit \(title)", height: 26, cornerRadius: 6) {
          NeedsYouCards.onAnswer?(prompt, .submit)
        }
      }
    }
  }

  private func answerButton(_ row: PendingPrompt.Shown, first: Bool) -> some View {
    let option = row.option
    let toggles = option.checked != nil
    let label = (toggles ? (option.checked == true ? "☑ " : "☐ ") : "") + short(option.label)
    return HStack(spacing: 8) {
      if let hint = hint(row) { KeyHint(hint) }
      GlanceButton(label, style: first && !toggles ? .primary : .secondary, label: "\(label), \(title)", height: 26,
                   cornerRadius: 6) {
        NeedsYouCards.onAnswer?(prompt, row.answer)
      }
    }
  }

  // MARK: Free text

  private var placeholder: String? {
    guard PromptKeys.keys(.note("x"), kind: prompt.kind, screen: screen) != nil else { return nil }
    switch prompt.kind {
    case .permission: return "Tell Claude what to do instead…"
    case .question: return "Type an answer…"
    case .plan: return "What should change?"
    }
  }

  private func textField(_ placeholder: String) -> some View {
    TextField(placeholder, text: $model.draft)
      .textFieldStyle(.plain)
      .font(GlanceFont.sans(13))
      .foregroundStyle(GlanceColor.ink)
      .focused($fieldFocused)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
      .onSubmit { send(model.draft) }
      .onChange(of: model.focusField) { fieldFocused = true }
      .accessibilityLabel(placeholder)
  }
}

extension PendingPrompt {
  /// One answer the card shows as a button: the Nth shown is the one ⌥N gives.
  struct Shown: Identifiable {
    let position: Int
    let option: PromptOption
    let answer: PromptAnswer
    var id: Int { option.number }
  }

  /// The options shown as buttons: reachable by keys, not the free-text row (the text field is that), and not a
  /// Submit row when the Submit button shows. The view and the hotkeys both use this.
  var shownAnswers: [Shown] {
    let multi = screen.options.contains { $0.checked != nil }
    let submit = multi && PromptKeys.keys(.submit, kind: kind, screen: screen) != nil
    var shown: [Shown] = []
    for option in screen.options {
      if PromptScreen.isFreeText(option.label) { continue }
      if submit, option.checked == nil, PromptKeys.isSubmit(option.label) { continue }
      let answer: PromptAnswer = option.checked != nil ? .toggle(option.number) : .option(option.number)
      guard PromptKeys.keys(answer, kind: kind, screen: screen) != nil else { continue }
      shown.append(Shown(position: shown.count, option: option, answer: answer))
    }
    return shown
  }
}
