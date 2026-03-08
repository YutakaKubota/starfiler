import Foundation
import Darwin

enum UserPaths {
    static var homeDirectoryURL: URL {
        let userName = NSUserName()
        let normalizedUserName = normalizedUserName(from: userName)
        var candidates: [String?] = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            NSHomeDirectory(),
            homeDirectoryFromPasswordDB(),
            NSHomeDirectoryForUser(userName),
        ]

        if normalizedUserName != userName {
            candidates.append(NSHomeDirectoryForUser(normalizedUserName))
        }

        candidates.append("/Users/\(normalizedUserName)")
        if normalizedUserName != userName {
            candidates.append("/Users/\(userName)")
        }

        for candidate in candidates {
            guard let candidatePath = candidate, !candidatePath.isEmpty else {
                continue
            }

            let normalizedPath = normalizedHomePath(from: candidatePath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: normalizedPath, isDirectory: true).standardizedFileURL
            }
        }

        return URL(fileURLWithPath: "/Users/\(normalizedUserName)", isDirectory: true).standardizedFileURL
    }

    static var homeDirectoryPath: String {
        homeDirectoryURL.path
    }

    static var desktopDirectoryURL: URL {
        knownDirectoryURL(for: .desktopDirectory, fallbackComponent: "Desktop")
    }

    static var documentsDirectoryURL: URL {
        knownDirectoryURL(for: .documentDirectory, fallbackComponent: "Documents")
    }

    static var downloadsDirectoryURL: URL {
        knownDirectoryURL(for: .downloadsDirectory, fallbackComponent: "Downloads")
    }

    static var desktopDirectoryPath: String {
        desktopDirectoryURL.path
    }

    static var documentsDirectoryPath: String {
        documentsDirectoryURL.path
    }

    static var downloadsDirectoryPath: String {
        downloadsDirectoryURL.path
    }

    static func portableBookmarkPath(_ rawPath: String, fileManager: FileManager = .default) -> String {
        let resolvedPath = PathNormalizer.normalizeForComparison(resolveBookmarkPath(rawPath, fileManager: fileManager))
        let normalizedHomePath = PathNormalizer.normalizeForComparison(homeDirectoryPath)

        if resolvedPath == normalizedHomePath {
            return "~"
        }
        if resolvedPath.hasPrefix(normalizedHomePath + "/") {
            return "~" + String(resolvedPath.dropFirst(normalizedHomePath.count))
        }
        return resolvedPath
    }

    static func resolveBookmarkPath(_ rawPath: String, fileManager: FileManager = .default) -> String {
        let expandedPath = expandedPathByResolvingHomeVariables(rawPath)
        var standardizedPath = PathNormalizer.normalizeForComparison(expandedPath)

        if let relocatedPath = relocatedPathToCurrentHome(from: standardizedPath, fileManager: fileManager) {
            standardizedPath = relocatedPath
        }

        if let migratedDropboxPath = resolveDropboxPath(from: standardizedPath, fileManager: fileManager) {
            return PathNormalizer.resolveExistingPath(migratedDropboxPath, fileManager: fileManager)
        }

        return PathNormalizer.resolveExistingPath(standardizedPath, fileManager: fileManager)
    }

    static func expandHomeVariables(in rawPath: String) -> String {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return rawPath
        }

        let normalizedPath = normalizedHomeAliasPath(from: trimmedPath)

        let expandedHomePath: String
        if normalizedPath == "$HOME" || normalizedPath == "${HOME}" {
            expandedHomePath = homeDirectoryPath
        } else if normalizedPath.hasPrefix("$HOME/") {
            expandedHomePath = homeDirectoryPath + String(normalizedPath.dropFirst("$HOME".count))
        } else if normalizedPath.hasPrefix("${HOME}/") {
            expandedHomePath = homeDirectoryPath + String(normalizedPath.dropFirst("${HOME}".count))
        } else {
            expandedHomePath = normalizedPath
        }

        return (expandedHomePath as NSString).expandingTildeInPath
    }

    private static func expandedPathByResolvingHomeVariables(_ rawPath: String) -> String {
        let expandedPath = expandHomeVariables(in: rawPath)
        let normalizedPath = PathNormalizer.normalizeForComparison(expandedPath)
        guard !normalizedPath.isEmpty else {
            return rawPath
        }
        if isHomeRelativeShortcutPath(normalizedPath) {
            let homeRelativePath = homeDirectoryPath + "/" + normalizedPath
            return (homeRelativePath as NSString).expandingTildeInPath
        }
        return normalizedPath
    }

    private static func normalizedHomeAliasPath(from path: String) -> String {
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

    private static func isHomeRelativeShortcutPath(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        if path.contains("://") {
            return false
        }

        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("$HOME") || path.hasPrefix("${HOME}") {
            return false
        }

        if path == "." || path == ".." || path.hasPrefix("./") || path.hasPrefix("../") {
            return false
        }

        return true
    }

    private static func relocatedPathToCurrentHome(from path: String, fileManager: FileManager) -> String? {
        let standardizedPath = PathNormalizer.normalizeForComparison(path)
        let normalizedHomePath = PathNormalizer.normalizeForComparison(homeDirectoryPath)

        if standardizedPath == normalizedHomePath || standardizedPath.hasPrefix(normalizedHomePath + "/") {
            return standardizedPath
        }

        let pathComponents = URL(fileURLWithPath: standardizedPath).pathComponents
        guard pathComponents.count >= 3,
              pathComponents[1] == "Users",
              pathComponents[2] != "Shared"
        else {
            return nil
        }

        var relocatedPath = normalizedHomePath
        let suffixComponents = pathComponents.dropFirst(3)
        if !suffixComponents.isEmpty {
            relocatedPath += "/" + suffixComponents.joined(separator: "/")
        }

        let sourceExists = fileManager.fileExists(atPath: standardizedPath)
        guard !sourceExists else {
            return nil
        }

        return PathNormalizer.normalizeForComparison(relocatedPath)
    }

    private static func homeDirectoryFromPasswordDB() -> String? {
        guard let pw = getpwuid(getuid()), let homePtr = pw.pointee.pw_dir else {
            return nil
        }
        let home = String(cString: homePtr)
        return home.isEmpty ? nil : home
    }

    private static func normalizedUserName(from rawUserName: String) -> String {
        let trimmedUserName = rawUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserName.isEmpty else {
            return rawUserName
        }

        guard let separator = trimmedUserName.firstIndex(of: "@"), separator > trimmedUserName.startIndex else {
            return trimmedUserName
        }

        let sanitized = String(trimmedUserName[..<separator])
        return sanitized.isEmpty ? trimmedUserName : sanitized
    }

    private static func normalizedHomePath(from rawPath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: rawPath, isDirectory: true)
            .standardizedFileURL
            .path

        let marker = "/Library/Containers/"
        guard let markerRange = standardizedPath.range(of: marker) else {
            return standardizedPath
        }

        let unsandboxedPath = String(standardizedPath[..<markerRange.lowerBound])
        return unsandboxedPath.isEmpty ? standardizedPath : unsandboxedPath
    }

    private static func knownDirectoryURL(
        for directory: FileManager.SearchPathDirectory,
        fallbackComponent: String
    ) -> URL {
        if let resolvedURL = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            return resolvedURL.standardizedFileURL
        }
        return homeDirectoryURL
            .appendingPathComponent(fallbackComponent, isDirectory: true)
            .standardizedFileURL
    }

    private static func resolveDropboxPath(from path: String, fileManager: FileManager) -> String? {
        let suffix = dropboxRelativeSuffix(from: path)
        guard let suffix else {
            return nil
        }

        for root in discoverDropboxRoots(fileManager: fileManager) {
            let candidatePath = suffix.isEmpty ? root : root + suffix
            if fileManager.fileExists(atPath: candidatePath) {
                return PathNormalizer.normalizeForComparison(candidatePath)
            }
        }

        return nil
    }

    private static func dropboxRelativeSuffix(from path: String) -> String? {
        let legacyRoot = homeDirectoryPath + "/Dropbox"
        if path == legacyRoot {
            return ""
        }
        if path.hasPrefix(legacyRoot + "/") {
            return String(path.dropFirst(legacyRoot.count))
        }

        let cloudStorageRoot = homeDirectoryPath + "/Library/CloudStorage/"
        guard path.hasPrefix(cloudStorageRoot) else {
            return nil
        }

        let remainder = String(path.dropFirst(cloudStorageRoot.count))
        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let provider = parts.first, provider.lowercased().hasPrefix("dropbox") else {
            return nil
        }

        guard parts.count > 1 else {
            return ""
        }
        return "/" + parts[1]
    }

    private static func discoverDropboxRoots(fileManager: FileManager) -> [String] {
        var cloudRoots: [String] = []

        let cloudStorageURL = URL(fileURLWithPath: homeDirectoryPath + "/Library/CloudStorage", isDirectory: true)
        if let candidates = try? fileManager.contentsOfDirectory(
            at: cloudStorageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for candidate in candidates where candidate.lastPathComponent.lowercased().hasPrefix("dropbox") && candidate.isDirectory {
                cloudRoots.append(candidate.standardizedFileURL.path)
            }
        }

        var roots = cloudRoots
        if roots.isEmpty {
            let legacyRoot = homeDirectoryPath + "/Dropbox"
            var isLegacyDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: legacyRoot, isDirectory: &isLegacyDirectory), isLegacyDirectory.boolValue {
                roots.append(URL(fileURLWithPath: legacyRoot, isDirectory: true).standardizedFileURL.path)
            }
        }

        var seen: Set<String> = []
        var uniqueRoots: [String] = []
        for root in roots where !seen.contains(root) {
            seen.insert(root)
            uniqueRoots.append(root)
        }
        return uniqueRoots.sorted { lhs, rhs in
            let lhsName = URL(fileURLWithPath: lhs).lastPathComponent.lowercased()
            let rhsName = URL(fileURLWithPath: rhs).lastPathComponent.lowercased()
            if lhsName == rhsName {
                return lhs < rhs
            }
            if lhsName == "dropbox" {
                return true
            }
            if rhsName == "dropbox" {
                return false
            }
            return lhsName < rhsName
        }
    }
}

enum PathNormalizer {
    static func normalizeForComparison(_ rawPath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let normalizedUnicodePath = standardizedPath.precomposedStringWithCanonicalMapping
        guard normalizedUnicodePath != "/", normalizedUnicodePath.hasSuffix("/") else {
            return normalizedUnicodePath
        }
        return String(normalizedUnicodePath.dropLast())
    }

    static func resolveExistingPath(_ rawPath: String, fileManager: FileManager = .default) -> String {
        let normalizedPath = normalizeForComparison(rawPath)
        if fileManager.fileExists(atPath: normalizedPath) {
            return normalizedPath
        }

        for variant in unicodeVariants(of: normalizedPath) where fileManager.fileExists(atPath: variant) {
            return normalizeForComparison(variant)
        }

        guard normalizedPath.hasPrefix("/") else {
            return normalizedPath
        }

        if let matchedPath = resolveByScanningPathComponents(normalizedPath, fileManager: fileManager) {
            return normalizeForComparison(matchedPath)
        }

        return normalizedPath
    }

    static func isSameOrDescendant(_ childPath: String, of parentPath: String) -> Bool {
        let normalizedChildPath = normalizeForComparison(childPath)
        let normalizedParentPath = normalizeForComparison(parentPath)

        if normalizedChildPath == normalizedParentPath {
            return true
        }

        let parentPrefix = normalizedParentPath == "/" ? "/" : normalizedParentPath + "/"
        return normalizedChildPath.hasPrefix(parentPrefix)
    }

    private static func unicodeVariants(of path: String) -> [String] {
        var variants: [String] = []
        for candidate in [
            path.precomposedStringWithCanonicalMapping,
            path.decomposedStringWithCanonicalMapping,
            path.precomposedStringWithCompatibilityMapping,
            path.decomposedStringWithCompatibilityMapping,
        ] where !variants.contains(candidate) {
            variants.append(candidate)
        }
        return variants
    }

    private static func resolveByScanningPathComponents(_ path: String, fileManager: FileManager) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.first == "/", components.count >= 2 else {
            return nil
        }

        var resolvedPath = "/"
        for component in components.dropFirst() where !component.isEmpty {
            let expectedPath = resolvedPath == "/"
                ? "/" + component
                : resolvedPath + "/" + component

            if fileManager.fileExists(atPath: expectedPath) {
                resolvedPath = expectedPath
                continue
            }

            guard let matchedName = bestMatchingChildName(
                under: resolvedPath,
                targetName: component,
                fileManager: fileManager
            ) else {
                return nil
            }

            resolvedPath = resolvedPath == "/"
                ? "/" + matchedName
                : resolvedPath + "/" + matchedName
        }

        return resolvedPath
    }

    private static func bestMatchingChildName(
        under parentPath: String,
        targetName: String,
        fileManager: FileManager
    ) -> String? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: parentPath) else {
            return nil
        }

        if names.contains(targetName) {
            return targetName
        }

        let normalizedTarget = targetName.precomposedStringWithCanonicalMapping
        let matches = names.filter { $0.precomposedStringWithCanonicalMapping == normalizedTarget }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }
}

extension URL {
    private static let mediaImageExtensionWhitelist: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "avif", "svg", "ico"
    ]

    private static let mediaVideoExtensionWhitelist: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "3gp", "m2ts"
    ]

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var isPackage: Bool {
        (try? resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    var displayName: String {
        FileManager.default.displayName(atPath: path)
    }

    var isImageFile: Bool {
        if hasDirectoryPath {
            return false
        }

        let lowercasedExtension = pathExtension.lowercased()
        guard !lowercasedExtension.isEmpty else {
            return false
        }

        return Self.mediaImageExtensionWhitelist.contains(lowercasedExtension)
    }

    var isVideoFile: Bool {
        if hasDirectoryPath {
            return false
        }

        let lowercasedExtension = pathExtension.lowercased()
        guard !lowercasedExtension.isEmpty else {
            return false
        }

        return Self.mediaVideoExtensionWhitelist.contains(lowercasedExtension)
    }

    var isMediaFile: Bool {
        isImageFile || isVideoFile
    }

    var isMarkdownFile: Bool {
        if hasDirectoryPath {
            return false
        }

        let lowercasedExtension = pathExtension.lowercased()
        guard !lowercasedExtension.isEmpty else {
            return false
        }

        let markdownExtensions: Set<String> = [
            "md", "markdown", "mdown", "mkd", "mkdn"
        ]
        return markdownExtensions.contains(lowercasedExtension)
    }
}
