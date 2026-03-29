import Foundation

// MARK: - Terminal Sessions

extension MainWindowController {
    func launchTerminalSession(command: TerminalSessionCommand) {
        let workingDirectory = mainViewModel.activePane.paneState.currentDirectory
        let listVM = mainViewModel.terminalSessionListViewModel

        listVM.onSessionCreated = { [weak self] session in
            self?.openSessionWindow(id: session.id)
            self?.sessionManagerViewModel?.reloadSessions()
        }

        listVM.createSession(command: command, workingDirectory: workingDirectory)
    }

    func loadPersistedSessions() {
        Task { [weak self] in
            guard let self else { return }

            var restoredSessions: [TerminalSession] = []
            var restoredLogs: [UUID: [String]] = [:]

            if let config = self.configManager.loadTerminalSessionsConfig() {
                let data = config.toSessionsAndLogs()
                restoredSessions = data.sessions
                restoredLogs = data.logs
            }

            if restoredSessions.isEmpty {
                restoredSessions = ExternalSessionDiscovery.discoverExternalSessions(limit: ExternalSessionImport.maxSessions)
            }

            guard !restoredSessions.isEmpty else {
                return
            }

            let listVM = self.mainViewModel.terminalSessionListViewModel
            await listVM.service.loadPersistedSessions(restoredSessions, logs: restoredLogs)
            await listVM.reloadSessions()
            self.sessionManagerViewModel?.reloadSessions()
        }
    }

    static func discoverExternalSessions(limit: Int) -> [TerminalSession] {
        ExternalSessionDiscovery.discoverExternalSessions(limit: limit)
    }

    static func recentJSONLFiles(
        under root: URL,
        excludingPathComponents: [String],
        maxCandidates: Int
    ) -> [(url: URL, modificationDate: Date)] {
        ExternalSessionDiscovery.recentJSONLFiles(under: root, excludingPathComponents: excludingPathComponents, maxCandidates: maxCandidates)
    }

    static func codexSession(from url: URL, fallbackDate: Date) -> TerminalSession? {
        ExternalSessionDiscovery.codexSession(from: url, fallbackDate: fallbackDate)
    }

    static func claudeSession(from url: URL, fallbackDate: Date) -> TerminalSession? {
        ExternalSessionDiscovery.claudeSession(from: url, fallbackDate: fallbackDate)
    }

    static func prefixLines(from url: URL, maxBytes: Int, maxLines: Int) -> [String] {
        ExternalSessionDiscovery.prefixLines(from: url, maxBytes: maxBytes, maxLines: maxLines)
    }

    static func jsonObject(from line: String) -> [String: Any]? {
        ExternalSessionDiscovery.jsonObject(from: line)
    }

    static func normalizedDirectoryURL(from path: String?) -> URL {
        ExternalSessionDiscovery.normalizedDirectoryURL(from: path)
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        ExternalSessionDiscovery.parseISO8601Date(value)
    }

    static func cleanedUserPrompt(_ raw: String) -> String {
        ExternalSessionDiscovery.cleanedUserPrompt(raw)
    }
}
