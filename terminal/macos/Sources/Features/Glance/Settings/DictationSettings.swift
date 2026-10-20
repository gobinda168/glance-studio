import AppKit
import AVFoundation
import GlanceCore
import GlanceKit
import SwiftUI

/// Dictation (spec 2026-10-08-settings-design.md, "Sections"): the switch, the two permissions it needs, macOS's fn
/// setting when it gets in the way, and the key it uses. The words are the old Settings window's.
struct DictationSettings: View {
    let model: SettingsModel

    var body: some View {
        SettingsGroup(title: "Dictation") {
            SettingsRow(id: "dictation.enabled", name: "Hold fn to dictate",
                        detail: "Hold fn, speak, and let go: Glance types what you said where you're typing.") {
                SettingsSwitch(label: "Hold fn to dictate",
                               isOn: Binding(get: { model.dictationEnabled }, set: { model.setDictationEnabled($0) }))
            }
        }
        SettingsGroup(title: "Permissions") {
            permission(id: "dictation.microphone", name: "Microphone", granted: model.micStatus == .authorized,
                       detail: Self.micDetail(model.micStatus),
                       url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            permission(id: "dictation.accessibility", name: "Accessibility", granted: model.accessibilityGranted,
                       detail: model.accessibilityGranted ? "Allowed" : "Needed to see fn and type text",
                       url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        if let advice = model.fnUsage.advice {
            SettingsGroup(title: "The fn key") {
                SettingsRow(id: "dictation.fnKey", name: "Press 🌐 key to", detail: advice, light: false) {
                    StudioButton(title: "Open", height: 26) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                }
            }
        }
        SettingsGroup(title: "Speech to text") {
            SettingsRow(id: "dictation.key", name: "ElevenLabs key",
                        detail: !model.elevenLabsKey.hasSavedKey ? "Dictation uses your ElevenLabs key. Add it in Voice."
                            : model.elevenLabsKey.savedKeyMask.map { "Dictation uses your ElevenLabs key (\($0))." }
                            ?? "Dictation uses your saved ElevenLabs key.",
                        light: model.elevenLabsKey.hasSavedKey) {
                StudioButton(title: "Voice", height: 26) {
                    SettingsNavigation.shared.show(.voice, focus: "voice.elevenLabsKey")
                }
            }
        }
    }

    private func permission(id: String, name: String, granted: Bool, detail: String, url: String) -> some View {
        SettingsRow(id: id, name: name, detail: detail, light: granted) {
            if !granted {
                StudioButton(title: "Open System Settings", height: 26) { NSWorkspace.shared.open(URL(string: url)!) }
            }
        }
    }

    static func micDetail(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Allowed"
        case .notDetermined: "macOS asks the first time you hold fn"
        case .denied: "Denied: allow it in System Settings"
        case .restricted: "Restricted by this Mac's policy"
        @unknown default: "Unknown"
        }
    }
}

/// The Dictation preview: the fn key, the two permissions' lights, and how to try it.
struct DictationPreview: View {
    let model: SettingsModel

    var body: some View {
        PreviewCard {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 16) {
                    FnKeyCap(on: model.dictationEnabled)
                    lights
                    hint
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 20) {
                    FnKeyCap(on: model.dictationEnabled)
                    VStack(alignment: .leading, spacing: 10) {
                        lights
                        hint
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var lights: some View {
        VStack(alignment: .leading, spacing: 6) {
            light("Microphone", on: model.micStatus == .authorized)
            light("Accessibility", on: model.accessibilityGranted)
        }
    }

    private func light(_ name: String, on: Bool) -> some View {
        HStack(spacing: 7) {
            StatusLight(on: on)
            Text(name).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink)
            Text(on ? "Allowed" : "Not yet").font(.studio(12)).foregroundStyle(StudioColors.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var hint: some View {
        Text(model.dictationEnabled ? "Hold fn in any text field to try it" : "Dictation is off")
            .font(.studio(12.5))
            .foregroundStyle(model.dictationEnabled ? StudioColors.body : StudioColors.muted)
    }
}

/// A Mac's fn key, large: "fn" at the top right, the globe at the bottom left; faint while dictation is off.
private struct FnKeyCap: View {
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("fn").font(.studio(15, .medium))
            }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "globe").font(.system(size: 14, weight: .regular))
                Spacer()
            }
        }
        .foregroundStyle(StudioColors.ink)
        .padding(10)
        .frame(width: 64, height: 64)
        .background(shape.fill(StudioColors.solid))
        .overlay(shape.strokeBorder(StudioColors.line3, lineWidth: 1))
        .background(shape.fill(StudioColors.line3).offset(y: 2))
        .opacity(on ? 1 : 0.5)
        .accessibilityLabel("The fn key")
    }
}
