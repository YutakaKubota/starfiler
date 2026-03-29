import Foundation

enum PaneSide: Sendable {
    case left
    case right
}

enum PaneDisplayMode: String, Codable, CaseIterable, Sendable {
    case browser
    case media
}

struct PaneState: Hashable, Sendable {
    var currentDirectory: URL
    var cursorIndex: Int
    var markedIndices: IndexSet
    var visualAnchorIndex: Int?

    init(
        currentDirectory: URL,
        cursorIndex: Int = 0,
        markedIndices: IndexSet = [],
        visualAnchorIndex: Int? = nil
    ) {
        self.currentDirectory = currentDirectory
        self.cursorIndex = cursorIndex
        self.markedIndices = markedIndices
        self.visualAnchorIndex = visualAnchorIndex
    }
}

struct FilePaneSelection {
    private init() {}

    static func markedOrSelectedURLs(
        displayedItems: [FileItem],
        markedIndices: IndexSet,
        cursorIndex: Int
    ) -> [URL] {
        let markedURLs = markedIndices.compactMap { index -> URL? in
            guard displayedItems.indices.contains(index) else {
                return nil
            }
            return displayedItems[index].url.standardizedFileURL
        }

        if !markedURLs.isEmpty {
            return markedURLs
        }

        guard displayedItems.indices.contains(cursorIndex) else {
            return []
        }

        return [displayedItems[cursorIndex].url.standardizedFileURL]
    }

    static func toggledMarkedIndices(
        currentMarkedIndices: IndexSet,
        cursorIndex: Int,
        itemCount: Int
    ) -> IndexSet {
        guard itemCount > 0 else {
            return []
        }

        let clampedCursorIndex = min(max(cursorIndex, 0), itemCount - 1)
        var updated = clampedMarkedIndices(currentMarkedIndices, itemCount: itemCount)

        if updated.contains(clampedCursorIndex) {
            updated.remove(clampedCursorIndex)
        } else {
            updated.insert(clampedCursorIndex)
        }

        return updated
    }

    static func allMarkedIndices(itemCount: Int) -> IndexSet {
        guard itemCount > 0 else {
            return []
        }

        return IndexSet(integersIn: 0 ..< itemCount)
    }

    static func clampedMarkedIndices(_ markedIndices: IndexSet, itemCount: Int) -> IndexSet {
        guard itemCount > 0 else {
            return []
        }

        return markedIndices.reduce(into: IndexSet()) { partialResult, index in
            if index >= 0 && index < itemCount {
                partialResult.insert(index)
            }
        }
    }

    static func rangeMarkedIndices(anchorIndex: Int, currentIndex: Int, itemCount: Int) -> IndexSet {
        guard itemCount > 0 else {
            return []
        }

        let clampedAnchor = min(max(anchorIndex, 0), itemCount - 1)
        let clampedCurrent = min(max(currentIndex, 0), itemCount - 1)
        return IndexSet(integersIn: min(clampedAnchor, clampedCurrent) ... max(clampedAnchor, clampedCurrent))
    }

    static func clampedVisualAnchorIndex(_ visualAnchorIndex: Int?, itemCount: Int) -> Int? {
        guard let visualAnchorIndex else {
            return nil
        }

        guard itemCount > 0 else {
            return nil
        }

        return min(max(visualAnchorIndex, 0), itemCount - 1)
    }

    static func visualSelection(
        visualAnchorIndex: Int?,
        cursorIndex: Int,
        itemCount: Int
    ) -> IndexSet? {
        guard let visualAnchorIndex = clampedVisualAnchorIndex(visualAnchorIndex, itemCount: itemCount) else {
            return nil
        }

        return rangeMarkedIndices(
            anchorIndex: visualAnchorIndex,
            currentIndex: cursorIndex,
            itemCount: itemCount
        )
    }

    static func markedIndices(
        for markedURLs: Set<URL>,
        indexByURL: [URL: Int]
    ) -> IndexSet {
        markedURLs.reduce(into: IndexSet()) { partialResult, url in
            if let index = indexByURL[url] {
                partialResult.insert(index)
            }
        }
    }
}
