import Foundation
import Sparkle

/// Simulates various update scenarios for testing the update UI.
///
/// The expected usage is by overriding the `checkForUpdates` function in AppDelegate and
/// calling one of these instead. This will allow us to test the update flows without having to use
/// real updates. GLANCE: or, in a running Glance Studio, post `dev.glance.debug.simulateUpdate` with a case's name as
/// the object (AppDelegate).
enum UpdateSimulator: String {
    /// Complete successful update flow: checking → available → download → extract → ready → install → idle
    case happyPath

    /// No updates available: checking (2s) → "up to date", which fades on its own → idle
    case notFound

    /// Error during check: checking (2s) → error with retry callback
    case error

    /// Slower download for testing progress UI: checking → available → download (20 steps, ~10s) → extract → install
    case slowDownload

    /// Initial permission request flow: shows permission dialog → proceeds with happy path if accepted
    case permissionRequest

    /// User cancels during download: checking → available → download (5 steps) → cancels → idle
    case cancelDuringDownload

    /// User cancels while checking: checking (1s) → cancels → idle
    case cancelDuringChecking

    /// Shows the ready state with Restart Now (stays until answered)
    case installing

    /// Simulates auto-update flow: goes directly to installing state without showing intermediate UI
    case autoUpdate

    func simulate(with viewModel: UpdateViewModel) {
        switch self {
        case .happyPath:
            simulateHappyPath(viewModel)
        case .notFound:
            simulateNotFound(viewModel)
        case .error:
            simulateError(viewModel)
        case .slowDownload:
            simulateSlowDownload(viewModel)
        case .permissionRequest:
            simulatePermissionRequest(viewModel)
        case .cancelDuringDownload:
            simulateCancelDuringDownload(viewModel)
        case .cancelDuringChecking:
            simulateCancelDuringChecking(viewModel)
        case .installing:
            simulateReady(viewModel)
        case .autoUpdate:
            simulateAutoUpdate(viewModel)
        }
    }

    /// GLANCE: a stand-in update with a version and a build, as a real appcast has.
    private static func item() -> SUAppcastItem {
        let item = SUAppcastItem.empty()
        item.setValue("0.1.0", forKey: "_displayVersionString")
        item.setValue("99999", forKey: "_versionString")
        return item
    }

    private func simulateHappyPath(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: Self.item(),
                reply: { choice in
                    if choice == .install {
                        simulateDownload(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }

    private func simulateNotFound(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // GLANCE: the view model fades it.
            viewModel.state = .notFound(.init(acknowledgement: {
                // Acknowledgement called when dismissed
            }))
        }
    }

    private func simulateError(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .error(.init(
                error: NSError(domain: "UpdateError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to check for updates"
                ]),
                retry: {
                    simulateHappyPath(viewModel)
                },
                dismiss: {
                    viewModel.state = .idle
                }
            ))
        }
    }

    private func simulateSlowDownload(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: Self.item(),
                reply: { choice in
                    if choice == .install {
                        simulateSlowDownloadProgress(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }

    private func simulateSlowDownloadProgress(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)

        for i in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 2000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)

                if i == 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateExtract(viewModel)
                    }
                }
            }
        }
    }

    private func simulatePermissionRequest(_ viewModel: UpdateViewModel) {
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        viewModel.state = .permissionRequest(.init(
            request: request,
            reply: { response in
                if response.automaticUpdateChecks {
                    simulateHappyPath(viewModel)
                } else {
                    viewModel.state = .idle
                }
            }
        ))
    }

    private func simulateCancelDuringDownload(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: Self.item(),
                reply: { choice in
                    if choice == .install {
                        simulateDownloadThenCancel(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }

    private func simulateDownloadThenCancel(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)

        for i in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 1000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)

                if i == 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.state = .idle
                    }
                }
            }
        }
    }

    private func simulateCancelDuringChecking(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            viewModel.state = .idle
        }
    }

    private func simulateDownload(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)

        for i in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 1000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)

                if i == 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateExtract(viewModel)
                    }
                }
            }
        }
    }

    private func simulateExtract(_ viewModel: UpdateViewModel) {
        viewModel.state = .extracting(.init(progress: 0.0))

        for j in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(j) * 0.3) {
                viewModel.state = .extracting(.init(progress: Double(j) / 5.0))

                if j == 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateReady(viewModel)
                    }
                }
            }
        }
    }

    /// GLANCE: downloaded and prepared, waiting for Restart Now.
    private func simulateReady(_ viewModel: UpdateViewModel) {
        viewModel.state = .ready(.init(appcastItem: Self.item(), reply: { choice in
            if choice == .install {
                simulateRestart(viewModel)
            } else {
                viewModel.state = .idle
            }
        }))
    }

    /// GLANCE: "Restarting…", where the real app would quit, install and open again.
    private func simulateRestart(_ viewModel: UpdateViewModel) {
        viewModel.state = .installing(.init(retryTerminatingApplication: {}))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            viewModel.state = .idle
        }
    }

    private func simulateAutoUpdate(_ viewModel: UpdateViewModel) {
        viewModel.state = .installing(.init(
            appcastItem: Self.item(),
            retryTerminatingApplication: {
                print("Restart button clicked in simulator - resetting to idle")
                viewModel.state = .idle
            },
        ))
    }
}
