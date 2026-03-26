import AppKit

private struct LaunchOptions {
    let isUITest: Bool
    let sandboxRoot: URL?
    let configRoot: URL?
    let disableAnimations: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isUITest = arguments.contains("--uitest")
        sandboxRoot = Self.pathValue(for: "--sandbox-root", arguments: arguments).map {
            URL(fileURLWithPath: UserPaths.expandHomeVariables(in: $0), isDirectory: true).standardizedFileURL
        }
        configRoot = Self.pathValue(for: "--config-root", arguments: arguments).map {
            URL(fileURLWithPath: UserPaths.expandHomeVariables(in: $0), isDirectory: true).standardizedFileURL
        }
        disableAnimations = arguments.contains("--disable-animations")
    }

    private static func pathValue(for option: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

private actor UITestSecurityScopedBookmarkService: SecurityScopedBookmarkProviding {
    func loadBookmarks() async throws {}

    func hasBookmarks() async throws -> Bool { true }

    func saveBookmark(for url: URL) async throws {}

    func resolveBookmark(for url: URL) async throws -> URL? { url.standardizedFileURL }

    func startAccessing(_ url: URL) async throws {}

    func stopAccessing(_ url: URL) async {}
}

@main
enum StarfilerMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum FileClipboardPasteboard {
        static let operationType = NSPasteboard.PasteboardType("com.nilone.starfiler.clipboard-operation")
        static let copyOperationValue = "copy"
        static let cutOperationValue = "cut"
    }

    private let launchOptions = LaunchOptions()
    let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    var mainWindowController: MainWindowController?
    var settingsWindowController: SettingsWindowController?
    var syncStatusBarController: SyncStatusBarController?
    var networkSyncViewModel: NetworkSyncViewModel?
    private var launchTask: Task<Void, Never>?
    private var pendingOpenDirectories: [URL] = []
    var fileClipboardChangeCount: Int?
    private let securityScopedBookmarkService: any SecurityScopedBookmarkProviding = SecurityScopedBookmarkService.shared
    lazy var activeSecurityScopedBookmarkService: any SecurityScopedBookmarkProviding = {
        launchOptions.isUITest ? UITestSecurityScopedBookmarkService() : securityScopedBookmarkService
    }()
    lazy var sharedConfigManager: ConfigManager = {
        makeConfigManagerOverride() ?? ConfigManager()
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        launchTask = Task { @MainActor in
            await launchMainWindow()
            await setupNetworkSync()
            launchTask = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(networkSyncViewModel?.isEnabled ?? false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkSyncViewModel?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpenDirectories(from: urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        enqueueOpenDirectories(from: urls)
        sender.reply(toOpenOrPrint: .success)
    }

    @MainActor
    private func launchMainWindow() async {
        do {
            try await activeSecurityScopedBookmarkService.loadBookmarks()

            let hasBookmarks = try await activeSecurityScopedBookmarkService.hasBookmarks()
            if !hasBookmarks, !launchOptions.isUITest {
                guard let selectedStartupDisk = requestStartupDiskAccess() else {
                    NSApp.terminate(nil)
                    return
                }
                try await activeSecurityScopedBookmarkService.saveBookmark(for: selectedStartupDisk)
            }

            let initialDirectory = launchOptions.sandboxRoot ?? UserPaths.homeDirectoryURL
            let controller = MainWindowController(
                securityScopedBookmarkService: activeSecurityScopedBookmarkService,
                initialDirectory: initialDirectory,
                configManager: sharedConfigManager,
                disableAnimations: launchOptions.disableAnimations,
                persistLaunchMetadata: !launchOptions.isUITest
            )
            mainWindowController = controller
            controller.showWindow(self)
            configureNetworkSyncIfNeeded()
            processPendingOpenDirectories()

            NSApp.activate(ignoringOtherApps: true)
        } catch {
            presentStartupError(error)
        }
    }

    private func makeConfigManagerOverride() -> ConfigManager? {
        guard let configRoot = launchOptions.configRoot else {
            return nil
        }
        return ConfigManager(configDirectory: configRoot)
    }

    @MainActor
    private func requestStartupDiskAccess() -> URL? {
        let startupDiskURL = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL
        let panel = NSOpenPanel()
        panel.directoryURL = startupDiskURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "starfiler requires directory access. Select the startup disk (Macintosh HD) to reduce future permission prompts."

        guard panel.runModal() == .OK, let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }

        return selectedURL
    }

    @MainActor
    private func presentStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to initialize sandbox access."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func enqueueOpenDirectories(from urls: [URL]) {
        let directories = urls.compactMap(resolveDirectoryToOpen(from:))
        guard !directories.isEmpty else {
            return
        }

        pendingOpenDirectories.append(contentsOf: directories)
        Task { @MainActor in
            processPendingOpenDirectories()
        }
    }

    private func resolveDirectoryToOpen(from url: URL) -> URL? {
        let fileURL = url.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return fileURL
        }

        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    @MainActor
    private func processPendingOpenDirectories() {
        guard let mainWindowController, !pendingOpenDirectories.isEmpty else {
            return
        }

        let targetDirectory = pendingOpenDirectories.removeLast()
        pendingOpenDirectories.removeAll(keepingCapacity: true)

        mainWindowController.performAction {
            $0.activePane.navigate(to: targetDirectory)
        }
    }
}
