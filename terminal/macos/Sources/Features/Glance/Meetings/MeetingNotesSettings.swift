import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Meetings → Meeting notes (spec 2026-10-09-meeting-notes-design.md): the transcription model (on this
/// Mac or not, its size, Download and Remove), Join & Record on the nudge, and Keep recordings. Shown while the Meeting
/// Notes feature is on.
struct MeetingNotesSettings: View {
    @StateObject private var model = MeetingNotesSettingsModel()
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        SettingsGroup(title: "Meeting notes") {
            SettingsRow(id: "meetings.notesModel", name: "Transcription model", detail: model.detail,
                        light: model.downloaded) {
                if model.downloading {
                    ProgressView().controlSize(.small)
                } else if model.downloaded {
                    StudioButton(title: "Remove", enabled: !recorder.isBusy) { model.remove() }
                } else {
                    StudioButton(title: "Download", enabled: !recorder.isBusy) { model.download() }
                }
            }
            SettingsRow(id: "meetings.notesOffer", name: "Join & Record",
                        detail: "The meeting nudge offers Join & Record next to Join (Record for a meeting without a link).") {
                SettingsSwitch(label: "Join & Record", isOn: Binding(get: { model.offer }, set: { model.setOffer($0) }))
            }
            SettingsRow(id: "meetings.notesCalls", name: "Offer to record calls",
                        detail: "When Zoom, Teams, Slack, FaceTime or a browser starts using the mic, a pill offers "
                            + "Record. Glance only checks which apps use the mic, never what they hear.") {
                SettingsSwitch(label: "Offer to record calls",
                               isOn: Binding(get: { model.offerCalls }, set: { model.setOfferCalls($0) }))
            }
            SettingsRow(id: "meetings.notesKeepAudio", name: "Keep recordings",
                        detail: "Off: a meeting's audio is deleted once its notes are done; the transcript and notes "
                            + "stay. On: the audio stays in Application Support/Glance/Meetings.") {
                SettingsSwitch(label: "Keep recordings", isOn: Binding(get: { model.keep }, set: { model.setKeep($0) }))
            }
        }
        .onAppear { model.reload() }
    }
}

@MainActor
final class MeetingNotesSettingsModel: ObservableObject {
    @Published private(set) var downloaded = MeetingSpeechModels.isDownloaded
    @Published private(set) var size: Int64 = 0
    @Published private(set) var downloading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var failure: String?
    @Published private(set) var offer = Prefs.meetingOfferRecording
    @Published private(set) var keep = Prefs.meetingKeepRecordings
    @Published private(set) var offerCalls = Prefs.meetingOfferCalls

    var detail: String {
        if downloading { return "Downloading Parakeet… \(Int(progress * 100))%" }
        if let failure { return "Couldn't download: \(failure)" }
        if downloaded {
            return "Parakeet, on this Mac (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))). It "
                + "loads only while a meeting is transcribed."
        }
        return "Parakeet (about 600 MB) transcribes on this Mac. The first recording downloads it, or download it now."
    }

    func reload() {
        downloaded = MeetingSpeechModels.isDownloaded
        Task.detached {
            let size = MeetingSpeechModels.sizeOnDisk()
            await MainActor.run { self.size = size }
        }
    }

    func download() {
        guard !downloading else { return }
        downloading = true
        failure = nil
        progress = 0
        Task { @MainActor in
            do {
                try await MeetingSpeechModels.shared.loadTranscription { fraction, _ in
                    Task { @MainActor in self.progress = fraction }
                }
                // Downloaded and compiled; it isn't needed until a meeting.
                await MeetingSpeechModels.shared.releaseTranscription()
            } catch {
                failure = error.localizedDescription
            }
            downloading = false
            reload()
        }
    }

    func remove() {
        do {
            try MeetingSpeechModels.remove()
        } catch {
            failure = error.localizedDescription
        }
        reload()
    }

    func setOffer(_ on: Bool) {
        Prefs.meetingOfferRecording = on
        offer = on
        MeetingNudger.shared.refresh()
    }

    func setOfferCalls(_ on: Bool) {
        Prefs.meetingOfferCalls = on
        offerCalls = on
        on ? CallNudger.shared.start() : CallNudger.shared.stop()
    }

    func setKeep(_ on: Bool) {
        Prefs.meetingKeepRecordings = on
        keep = on
    }
}
