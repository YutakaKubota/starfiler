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
                restoredSessions = Self.discoverExternalSessions(limit: ExternalSessionImport.maxSessions)
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
        let codexSessions = discoverCodexSessions(limit: limit)
        let claudeSessions = discoverClaudeSessions(limit: limit)
        let merged = codexSessions + claudeSessions

        guard !merged.isEmpty else {
            return []
        }

        var deduplicated: [UUID: TerminalSession] = [:]
        for session in merged {
            if let existing = deduplicated[session.id] {
                deduplicated[session.id] = session.lastActivityAt > existing.lastActivityAt ? session : existing
            } else {
                deduplicated[session.id] = session
            }
        }

        return deduplicated.values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(limit)
            .map { $0 }
    }

    private static func discoverCodexSessions(limit: Int) -> [TerminalSession] {
        let root = UserPaths.homeDirectoryURL.appendingPathComponent(ExternalSessionImport.codexRelativePath, isDirectory: true)
        let candidates = recentJSONLFiles(
            under: root,
            excludingPathComponents: [],
            maxCandidates: max(limit * ExternalSessionImport.codexScanMultiplier, limit)
        )
        guard !candidates.isEmpty else {
            return []
        }

        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(limit)
        for candidate in candidates {
            guard let session = codexSession(from: candidate.url, fallbackDate: candidate.modificationDate) else {
                continue
            }
            sessions.append(session)
            if sessions.count >= limit {
                break
            }
        }

        return sessions
    }

    private static func discoverClaudeSessions(limit: Int) -> [TerminalSession] {
        let root = UserPaths.homeDirectoryURL.appendingPathComponent(ExternalSessionImport.claudeRelativePath, isDirectory: true)
        let candidates = recentJSONLFiles(
            under: root,
            excludingPathComponents: ["subagents", "tool-results"],
            maxCandidates: max(limit * ExternalSessionImport.claudeScanMultiplier, limit)
        )
        guard !candidates.isEmpty else {
            return []
        }

        var sessions: [TerminalSession] = []
        sessions.reserveCapacity(limit)
        for candidate in candidates {
            guard let session = claudeSession(from: candidate.url, fallbackDate: candidate.modificationDate) else {
                continue
            }
            sessions.append(session)
            if sessions.count >= limit {
                break
            }
        }

        return sessions
    }

    static func recentJSONLFiles(
        under root: URL,
        excludingPathComponents: [String],
        maxCandidates: Int
    ) -> [(url: URL, modificationDate: Date)] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modificationDate: Date)] = []
        candidates.reserveCapacity(maxCandidates)

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else {
                continue
            }

            let path = fileURL.path
            if excludingPathComponents.contains(where: { path.contains("/\($0)/") }) {
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true
            else {
                continue
            }

            let modificationDate = values.contentModificationDate ?? .distantPast
            candidates.append((url: fileURL, modificationDate: modificationDate))
        }

        guard !candidates.isEmpty else {
            return []
        }

        return candidates
            .sorted { $0.modificationDate > $1.modificationDate }
            .prefix(maxCandidates)
            .map { $0 }
    }

    static func codexSession(from url: URL, fallbackDate: Date) -> TerminalSession? {
        let lines = prefixLines(from: url, maxBytes: ExternalSessionImport.maxReadBytesPerFile, maxLines: 80)
        guard !lines.isEmpty else {
            return nil
        }

        for line in lines where line.contains("\"type\":\"session_meta\"") {
            guard let json = jsonObject(from: line),
                  let payload = json["payload"] as? [String: Any]
            else {
                continue
            }

            let sessionIdentifier = (payload["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let sessionID = UUID(uuidString: sessionIdentifier) ?? UUID()
            let cwd = payload["cwd"] as? String
            let directoryURL = normalizedDirectoryURL(from: cwd)
            let timestamp = (payload["timestamp"] as? String) ?? (json["timestamp"] as? String)
            let activityDate = parseISO8601Date(timestamp) ?? fallbackDate
            let directoryName = directoryURL.lastPathComponent
            let title = directoryName.isEmpty ? "Codex Session" : "Codex \(directoryName)"

            return TerminalSession(
                id: sessionID,
                title: title,
                status: .stopped,
                command: .codex,
                workingDirectory: directoryURL,
                exitCode: nil,
                createdAt: activityDate,
                lastActivityAt: activityDate,
                isPinned: false,
                lastOpenedAt: activityDate,
                updatedAt: activityDate
            )
        }

        return nil
    }

    static func claudeSession(from url: URL, fallbackDate: Date) -> TerminalSession? {
        let lines = prefixLines(from: url, maxBytes: ExternalSessionImport.maxReadBytesPerFile, maxLines: 120)
        guard !lines.isEmpty else {
            return nil
        }

        var sessionIdentifier: String?
        var cwd: String?
        var timestamp: String?
        var slug: String?
        var userPromptTitle: String?

        for line in lines {
            guard let json = jsonObject(from: line) else {
                continue
            }

            if sessionIdentifier == nil {
                sessionIdentifier = json["sessionId"] as? String
            }
            if cwd == nil {
                cwd = json["cwd"] as? String
            }
            if timestamp == nil {
                timestamp = json["timestamp"] as? String
            }
            if slug == nil {
                slug = json["slug"] as? String
            }

            if userPromptTitle == nil,
               let type = json["type"] as? String,
               type == "user",
               let message = json["message"] as? [String: Any],
               let role = message["role"] as? String,
               role == "user",
               let content = message["content"] as? String
            {
                let cleaned = cleanedUserPrompt(content)
                if !cleaned.isEmpty {
                    userPromptTitle = cleaned
                }
            }
        }

        let identifier = sessionIdentifier ?? url.deletingPathExtension().lastPathComponent
        guard !identifier.isEmpty else {
            return nil
        }

        let sessionID = UUID(uuidString: identifier) ?? UUID()
        let directoryURL = normalizedDirectoryURL(from: cwd)
        let activityDate = parseISO8601Date(timestamp) ?? fallbackDate
        let directoryName = directoryURL.lastPathComponent

        let title: String
        if let userPromptTitle, !userPromptTitle.isEmpty {
            title = userPromptTitle
        } else if let slug, !slug.isEmpty {
            title = "Claude \(slug)"
        } else if !directoryName.isEmpty {
            title = "Claude \(directoryName)"
        } else {
            title = "Claude Session"
        }

        return TerminalSession(
            id: sessionID,
            title: title,
            status: .stopped,
            command: .claude,
            workingDirectory: directoryURL,
            exitCode: nil,
            createdAt: activityDate,
            lastActivityAt: activityDate,
            isPinned: false,
            lastOpenedAt: activityDate,
            updatedAt: activityDate
        )
    }

    static func prefixLines(from url: URL, maxBytes: Int, maxLines: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        try? handle.close()

        guard !data.isEmpty else {
            return []
        }

        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(maxLines)
            .map(String.init)
    }

    static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    static func normalizedDirectoryURL(from path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return UserPaths.homeDirectoryURL
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        let formatterWithFractionalSeconds = ISO8601DateFormatter()
        formatterWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatterWithFractionalSeconds.date(from: value) {
            return parsed
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func cleanedUserPrompt(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return ""
        }

        return String(cleaned.prefix(80))
    }
}
