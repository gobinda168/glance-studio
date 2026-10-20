import GlanceCore

/// Studio's door to the prompt cards (spec 2026-10-11-needs-input-orb-design.md §3): the cards live in the orb
/// channel's floating panel, ahead of its own cards, and work whether or not the channel is on.
@MainActor
public enum NeedsYouCards {
  public static var onAnswer: ((PendingPrompt, PromptAnswer) -> Void)?
  public static var onOpen: ((PendingPrompt) -> Void)?

  /// Every pending prompt, oldest first. A prompt shows only once revealed.
  public static func update(_ prompts: [PendingPrompt]) { ChannelCards.shared.update(prompts: prompts) }

  /// Show this prompt's card (nil: every pending prompt's), optionally taking the keyboard.
  public static func reveal(_ prompt: PendingPrompt?, takeKeyboard: Bool) {
    ChannelCards.shared.reveal(prompt, takeKeyboard: takeKeyboard)
  }

  /// The card's dialog was gone when its answer was about to be typed.
  public static func answeredElsewhere(_ surface: String) { ChannelCards.shared.answeredElsewhere(surface) }
}
