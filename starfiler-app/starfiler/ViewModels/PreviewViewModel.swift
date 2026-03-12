import Foundation
import Observation

@MainActor
@Observable
final class PreviewViewModel {
    struct MediaItem: Sendable, Equatable {
        let url: URL
        let dateModified: Date?

        init(url: URL, dateModified: Date?) {
            self.url = url.standardizedFileURL
            self.dateModified = dateModified
        }
    }

    struct State: Sendable, Equatable {
        var selectedFileURL: URL?
        var selectedFileDateModified: Date?
        var currentDirectoryURL: URL?
        var siblingMediaItems: [MediaItem]

        var siblingMediaURLs: [URL] {
            siblingMediaItems.map(\.url)
        }

        static let `default` = State(
            selectedFileURL: nil,
            selectedFileDateModified: nil,
            currentDirectoryURL: nil,
            siblingMediaItems: []
        )
    }

    private(set) var state: State {
        didSet {
            onStateChanged?(state)
        }
    }

    var onStateChanged: ((State) -> Void)?

    init(state: State = .default) {
        self.state = state
    }

    func updateContext(
        selectedItem: FileItem?,
        currentDirectoryURL: URL,
        displayedItems: [FileItem]
    ) {
        let selectedFileURL = normalizedPreviewableURL(from: selectedItem)
        let selectedFileDateModified = selectedFileURL == nil ? nil : selectedItem?.dateModified

        let siblingMediaItems = displayedItems.compactMap { item -> MediaItem? in
            if item.isDirectory && !item.isPackage {
                return nil
            }
            guard item.url.isMediaFile else {
                return nil
            }
            return MediaItem(url: item.url, dateModified: item.dateModified)
        }

        let nextState = State(
            selectedFileURL: selectedFileURL,
            selectedFileDateModified: selectedFileDateModified,
            currentDirectoryURL: currentDirectoryURL,
            siblingMediaItems: siblingMediaItems
        )

        guard state != nextState else {
            return
        }

        state = nextState
    }

    func updateSelection(selectedItem: FileItem?) {
        let selectedFileURL = normalizedPreviewableURL(from: selectedItem)
        let selectedFileDateModified = selectedFileURL == nil ? nil : selectedItem?.dateModified
        let normalizedCurrent = state.selectedFileURL?.standardizedFileURL
        let normalizedNext = selectedFileURL?.standardizedFileURL
        guard normalizedCurrent != normalizedNext || state.selectedFileDateModified != selectedFileDateModified else {
            return
        }

        var updated = state
        updated.selectedFileURL = selectedFileURL
        updated.selectedFileDateModified = selectedFileDateModified
        state = updated
    }

    func setSelectedFileURL(_ url: URL?) {
        let normalizedCurrent = state.selectedFileURL?.standardizedFileURL
        let normalizedNext = url?.standardizedFileURL
        guard normalizedCurrent != normalizedNext else {
            return
        }

        var updated = state
        updated.selectedFileURL = normalizedNext
        updated.selectedFileDateModified = nil
        state = updated
    }

    private func normalizedPreviewableURL(from selectedItem: FileItem?) -> URL? {
        if let selectedItem, selectedItem.isDirectory, !selectedItem.isPackage {
            return nil
        }
        return selectedItem?.url.standardizedFileURL
    }
}
