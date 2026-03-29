import AppKit

extension MainSplitViewController {

    func resolveNavigationDestination(from rawInput: String) -> URL? {
        let sanitizedInput = stripSurroundingQuotes(from: rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !sanitizedInput.isEmpty else {
            return nil
        }

        let homeAliasNormalizedInput = normalizedHomeAliasPath(from: sanitizedInput)
        let expandedPath = (homeAliasNormalizedInput as NSString).expandingTildeInPath
        let currentDirectory = viewModel.activePane.paneState.currentDirectory
        let rawURL: URL
        if expandedPath.hasPrefix("/") {
            rawURL = URL(fileURLWithPath: expandedPath)
        } else {
            rawURL = URL(fileURLWithPath: expandedPath, relativeTo: currentDirectory)
        }

        let normalizedURL = rawURL.standardizedFileURL
        let resolvedPath = PathNormalizer.resolveExistingPath(normalizedURL.path)
        let resolvedURL = URL(fileURLWithPath: resolvedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return resolvedURL
        }

        return resolvedURL.deletingLastPathComponent().standardizedFileURL
    }

    private func normalizedHomeAliasPath(from path: String) -> String {
        let lowercasedPath = path.lowercased()
        if lowercasedPath == "home" {
            return "~"
        }

        let prefix = "home/"
        guard lowercasedPath.hasPrefix(prefix) else {
            return path
        }

        let suffixStart = path.index(path.startIndex, offsetBy: prefix.count)
        return "~/" + String(path[suffixStart...])
    }

    private func stripSurroundingQuotes(from value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }

        return value
    }

    func navigateActivePane(to destination: URL, selecting itemURL: URL? = nil) {
        let normalizedDestination = destination.standardizedFileURL
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.viewModel.securityScopedBookmarkService.startAccessing(normalizedDestination)
                await self.viewModel.securityScopedBookmarkService.stopAccessing(normalizedDestination)
                await MainActor.run {
                    if let itemURL {
                        self.viewModel.activePane.navigate(to: normalizedDestination, selecting: itemURL)
                        self.focusActivePane()
                    } else {
                        self.viewModel.activePane.navigate(to: normalizedDestination)
                    }
                }
            } catch let bookmarkError as SecurityScopedBookmarkError {
                switch bookmarkError {
                case .bookmarkNotFound:
                    await MainActor.run {
                        self.presentAccessGrantPrompt(for: normalizedDestination)
                    }
                default:
                    await MainActor.run {
                        self.presentNavigationErrorAlert(for: normalizedDestination, error: bookmarkError)
                    }
                }
            } catch {
                await MainActor.run {
                    self.presentNavigationErrorAlert(for: normalizedDestination, error: error)
                }
            }
        }
    }

    func presentPathNotFoundAlert(path: String) {
        presentErrorAlert(title: "Path not found", informativeText: path)
    }

    func presentAccessGrantPrompt(for destination: URL) {
        let panel = NSOpenPanel()
        panel.title = "Grant Folder Access"
        panel.message = "Select the bookmark folder (or one of its parent folders) to allow navigation."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = destination

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return
        }

        guard isSameOrDescendant(destination, of: selectedURL) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Selected folder does not contain bookmark"
            alert.informativeText = "Choose \(destination.path) or one of its parent folders."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await self.viewModel.securityScopedBookmarkService.saveBookmark(for: selectedURL)
                await MainActor.run {
                    self.viewModel.activePane.navigate(to: destination)
                }
            } catch {
                await MainActor.run {
                    self.presentNavigationErrorAlert(for: selectedURL, error: error)
                }
            }
        }
    }

    func presentNavigationErrorAlert(for destination: URL, error: Error) {
        presentErrorAlert(
            title: "Failed to open path",
            informativeText: "\(destination.path)\n\n\(error.localizedDescription)"
        )
    }

    func presentBookmarkPermissionSaveError(for destination: URL, error: Error) {
        presentErrorAlert(
            title: "Bookmark saved without access permission",
            informativeText:
                "\(destination.path)\n\n" +
                "You can keep this bookmark, but navigation may fail until access is granted.\n\n" +
                error.localizedDescription
        )
    }

    func presentErrorAlert(title: String, informativeText: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
        return PathNormalizer.isSameOrDescendant(childPath, of: parentPath)
    }
}
