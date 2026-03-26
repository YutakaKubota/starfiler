import AppKit

final class SettingsWindowController: NSWindowController {
    private let tabViewController = NSTabViewController()

    convenience init(
        appearanceVC: AppearanceSettingsViewController,
        keybindingsVC: KeybindingsViewController,
        bookmarksVC: BookmarksSettingsViewController,
        advancedVC: AdvancedSettingsViewController,
        networkSyncVC: NetworkSyncSettingsViewController? = nil
    ) {
        self.init(
            appearanceVC: appearanceVC,
            keybindingsVC: keybindingsVC,
            bookmarksVC: bookmarksVC,
            networkSyncVC: NetworkSyncSettingsViewController(),
            advancedVC: advancedVC
        )
    }

    init(
        appearanceVC: AppearanceSettingsViewController,
        keybindingsVC: KeybindingsViewController,
        bookmarksVC: BookmarksSettingsViewController,
        networkSyncVC: NetworkSyncSettingsViewController,
        advancedVC: AdvancedSettingsViewController
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 920, height: 700)

        super.init(window: window)

        tabViewController.tabStyle = .toolbar

        let appearanceItem = NSTabViewItem(viewController: appearanceVC)
        appearanceItem.label = "Appearance"
        appearanceItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Appearance")

        let keybindingsItem = NSTabViewItem(viewController: keybindingsVC)
        keybindingsItem.label = "Keybindings"
        keybindingsItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keybindings")

        let bookmarksItem = NSTabViewItem(viewController: bookmarksVC)
        bookmarksItem.label = "Bookmarks"
        bookmarksItem.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmarks")

        let networkSyncItem = NSTabViewItem(viewController: networkSyncVC)
        networkSyncItem.label = "Network Sync"
        networkSyncItem.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "Network Sync")

        let advancedItem = NSTabViewItem(viewController: advancedVC)
        advancedItem.label = "Advanced"
        advancedItem.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "Advanced")

        tabViewController.addTabViewItem(appearanceItem)
        tabViewController.addTabViewItem(keybindingsItem)
        tabViewController.addTabViewItem(bookmarksItem)
        tabViewController.addTabViewItem(networkSyncItem)
        tabViewController.addTabViewItem(advancedItem)

        window.contentViewController = tabViewController
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
