import AppKit
import GlanceCore
import SwiftUI

/// "owner/name isn't on this Mac", with Clone… and Choose Folder… (spec 2026-10-08-pr-repositories-design.md, "The
/// notice"): under a PR or Review comments tab's header while the repository has no folder here, and in the side bar
/// while Raise's clone runs. A clone shows its progress and Cancel; a failed clone (with Retry) or link says why.
struct LocalFolderNotice: View {
    let repository: String
    let window: NSWindow?
    @ObservedObject private var folders = RepositoryFoldersModel.shared

    /// The tooltip of a control that needs the repository's folder.
    static func needs(_ repository: String) -> String { "Needs \(repository) on this Mac" }

    var body: some View {
        let work = folders.work[RepositoryFolders.key(repository)]
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    line(work)
                    Spacer(minLength: 8)
                    buttons(work)
                }
                VStack(alignment: .leading, spacing: 8) {
                    line(work)
                    HStack(spacing: 8) { buttons(work) }
                }
            }
            switch work {
            case .cloneFailed(let message)?:
                InlineError(message: message) { folders.clone(repository, from: window) }
            case .linkFailed(let message)?:
                InlineError(message: message)
            case .cloning?, nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
    }

    @ViewBuilder private func line(_ work: RepositoryFoldersModel.Work?) -> some View {
        HStack(spacing: 8) {
            if work == .cloning {
                Spinner(size: 13)
            } else {
                StudioIcon(.folder, size: 14).foregroundStyle(StudioColors.muted)
            }
            Text(work == .cloning ? "Cloning \(repository)…" : "\(repository) isn't on this Mac")
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private func buttons(_ work: RepositoryFoldersModel.Work?) -> some View {
        if work == .cloning {
            StudioButton(title: "Cancel", style: .quiet, height: 26) { folders.cancelClone(repository) }
        } else {
            StudioButton(title: "Clone…", icon: .download, height: 26) { folders.clone(repository, from: window) }
            StudioButton(title: "Choose Folder…", height: 26) { folders.chooseFolder(for: repository, from: window) }
        }
    }
}
