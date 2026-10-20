import Foundation
import SwiftUI
import Sparkle

class UpdateViewModel: ObservableObject {
    // GLANCE: "up to date" fades on its own; Ghostty's pill did this in its view, and the toast shows in every window.
    @Published var state: UpdateState = .idle {
        didSet { fadeIfUpToDate() }
    }

    /// GLANCE: how long "up to date" stays on the toast.
    var upToDateFade: Duration = .seconds(4)
    private var fadeTask: Task<Void, Never>?

    /// The text to display for the current update state.
    /// Returns an empty string for idle state, progress percentages for downloading/extracting,
    /// or descriptive text for other states.
    var text: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Enable Automatic Updates?"
        case .checking:
            return "Checking for Updates…"
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return "Update Available: \(version)"
            }
            return "Update Available"
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                return String(format: "Downloading: %.0f%%", progress * 100)
            }
            return "Downloading…"
        case .extracting(let extracting):
            return String(format: "Preparing: %.0f%%", extracting.progress * 100)
        case .ready:
            return "Restart to Complete Update"
        case let .installing(install):
            return install.appcastItem != nil ? "Restart to Complete Update" : "Installing…"
        case .notFound:
            return "No Updates Available"
        case .error(let err):
            return err.error.localizedDescription
        }
    }

    /// The SF Symbol icon name for the current update state.
    var iconName: String? {
        switch state {
        case .idle:
            return nil
        case .permissionRequest:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .updateAvailable:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "shippingbox"
        case .ready, .installing:
            return "power.circle"
        case .notFound:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    /// A longer description for the current update state.
    /// Used in contexts like the command palette where more detail is helpful.
    var description: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Configure automatic update preferences"
        case .checking:
            return "Please wait while we check for available updates"
        case .updateAvailable:
            return "Download it now; Glance Studio restarts when you say so"
        case .downloading:
            return "Downloading the update package"
        case .extracting:
            return "Extracting and preparing the update"
        case .ready:
            return "Downloaded and ready. Running terminal sessions end when Glance Studio restarts"
        case let .installing(install):
            if let item = install.appcastItem {
                return "The update is ready. Version: \(item.displayVersionString)"
            } else {
                return "Installing update and preparing to restart"
            }
        case .notFound:
            return "You are running the latest version"
        case .error:
            return "An error occurred during the update process"
        }
    }

    /// A badge to display for the current update state.
    /// Returns version numbers, progress percentages, or nil.
    var badge: String? {
        switch state {
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            return version.isEmpty ? nil : version
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let percentage = Double(download.progress) / Double(expectedLength) * 100
                return String(format: "%.0f%%", percentage)
            }
            return nil
        case .extracting(let extracting):
            return String(format: "%.0f%%", extracting.progress * 100)
        default:
            return nil
        }
    }

    /// GLANCE: after `upToDateFade`, "up to date" goes and Sparkle hears it was seen.
    private func fadeIfUpToDate() {
        fadeTask?.cancel()
        fadeTask = nil
        guard case .notFound(let notFound) = state else { return }
        let delay = upToDateFade
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, case .notFound = self.state else { return }
            self.state = .idle
            notFound.acknowledgement()
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case permissionRequest(PermissionRequest)
    case checking(Checking)
    case updateAvailable(UpdateAvailable)
    case notFound(NotFound)
    case error(Error)
    case downloading(Downloading)
    case extracting(Extracting)
    /// GLANCE: downloaded and prepared, waiting for Restart Now on the toast.
    case ready(Ready)
    case installing(Installing)

    /// True if we're installing an update triggered manually.
    var shouldTerminateWithoutWarning: Bool {
        if case .installing(let installing) = self {
            return installing.appcastItem == nil
        } else {
            return false
        }
    }

    /// This is true if we're in a state that can be force installed. 
    var isInstallable: Bool {
        switch self {
        case .checking,
                .updateAvailable,
                .downloading,
                .extracting,
                .ready,
                .installing:
            return true

        default:
            return false
        }
    }

    var isCancellable: Bool {
        cancelAction != nil
    }

    func cancel() {
        cancelAction?()
    }

    private var cancelAction: (() -> Void)? {
        switch self {
        case .idle:
            nil
        case .permissionRequest:
            nil
        case .checking(let checking):
            checking.cancel
        case .updateAvailable(let available):
            { available.reply(.dismiss) }
        case .downloading(let downloading):
            downloading.cancel
        case .notFound(let notFound):
            notFound.acknowledgement
        case .error(let err):
            err.dismiss
        case .extracting:
            nil
        case .ready(let ready):
            { ready.reply(.dismiss) }
        case .installing:
            nil
        }
    }

    /// Confirms or accepts the current update state.
    /// - For available updates: begins installation
    /// - For ready-to-install: proceeds with installation (GLANCE: `.ready`, after Restart Now)
    /// - For installing: suppress termination warnings and restart
    mutating func confirm() {
        switch self {
        case .updateAvailable(let available):
            available.reply(.install)
        case .ready(let ready):
            ready.reply(.install)
        case .installing(let installing):
            // Remove appcastItem so we can restart without any other alerts.
            var suppressTerminationWarnings = installing
            suppressTerminationWarnings.appcastItem = nil
            self = .installing(suppressTerminationWarnings)
            installing.retryTerminatingApplication()
        default:
            break
        }
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.permissionRequest, .permissionRequest):
            return true
        case (.checking, .checking):
            return true
        case (.updateAvailable(let lUpdate), .updateAvailable(let rUpdate)):
            return lUpdate.appcastItem.displayVersionString == rUpdate.appcastItem.displayVersionString
        case (.notFound, .notFound):
            return true
        case (.error(let lErr), .error(let rErr)):
            return lErr.error.localizedDescription == rErr.error.localizedDescription
        case (.downloading(let lDown), .downloading(let rDown)):
            return lDown.progress == rDown.progress && lDown.expectedLength == rDown.expectedLength
        case (.extracting(let lExt), .extracting(let rExt)):
            return lExt.progress == rExt.progress
        case (.ready(let lhs), .ready(let rhs)):
            return lhs.appcastItem?.versionString == rhs.appcastItem?.versionString
        case (.installing(let lhs), .installing(let rhs)):
            return lhs.appcastItem?.displayVersionString == rhs.appcastItem?.displayVersionString
        default:
            return false
        }
    }

    struct NotFound {
        let acknowledgement: () -> Void
    }

    struct PermissionRequest {
        let request: SPUUpdatePermissionRequest
        let reply: @Sendable (SUUpdatePermissionResponse) -> Void
    }

    struct Checking {
        let cancel: () -> Void
    }

    struct UpdateAvailable {
        let appcastItem: SUAppcastItem
        let reply: @Sendable (SPUUserUpdateChoice) -> Void
    }

    /// GLANCE: Sparkle's showReady, held until Restart Now (`.install`) or Later (`.dismiss`, which installs it when
    /// Glance Studio quits). The item comes from showUpdateFound; nil if Sparkle resumed an earlier download.
    struct Ready {
        let appcastItem: SUAppcastItem?
        let reply: @Sendable (SPUUserUpdateChoice) -> Void
    }

    struct Error {
        let error: any Swift.Error
        let retry: () -> Void
        let dismiss: () -> Void
    }

    struct Downloading {
        let cancel: () -> Void
        let expectedLength: UInt64?
        let progress: UInt64
    }

    struct Extracting {
        let progress: Double
    }

    struct Installing {
        /// Non-nil if this state is triggered by auto update
        var appcastItem: SUAppcastItem?
        let retryTerminatingApplication: () -> Void
    }
}
