import AppKit
import SwiftUI

private struct WorkspaceToolbar: View {
    @ObservedObject var store: EngineStore
    var body: some View {
        WorkspacePicker(store: store).frame(width: 230, alignment: .leading)
    }
}

private struct StatusToolbar: View {
    @ObservedObject var store: EngineStore
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(store.busy ? Theme.accent : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            Text(store.demo ? "Sample data" : store.busy ? "Agents working" : store.connected ? "Ready" : "Connecting")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(width: 120, alignment: .trailing)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuItemValidation {
    let store: EngineStore
    let options: LaunchOptions
    private var window: NSWindow?
    private var terminating = false
    init(options: LaunchOptions) {
        self.options = options
        store = EngineStore(options: options)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let width: CGFloat = options.compact ? 1050 : 1320
        let height: CGFloat = options.compact ? 740 : 900
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Agent Conductor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Theme.background)
        window.minSize = NSSize(width: 1050, height: 740)
        window.isReleasedWhenClosed = false
        let root = RootView().environmentObject(store).environment(\.colorScheme, .dark).tint(Theme.accent)
        window.contentView = NSHostingView(rootView: root)
        let toolbar = NSToolbar(identifier: "conductor-toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        self.window = window
        installMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        store.launch()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .flexibleSpace, .init("workspace"), .init("status")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .init("workspace"), .flexibleSpace, .init("status")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .toggleSidebar { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "workspace" {
            item.label = "Workspace"
            item.view = NSHostingView(rootView: WorkspaceToolbar(store: store).environment(\.colorScheme, .dark))
        } else {
            item.label = "Agent status"
            item.view = NSHostingView(rootView: StatusToolbar(store: store).environment(\.colorScheme, .dark))
        }
        return item
    }
    private func installMenu() {
        let bar = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agent Conductor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Agent Conductor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Agent Conductor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu
        bar.addItem(application)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newTask = fileMenu.addItem(withTitle: "New Chat", action: #selector(newTask), keyEquivalent: "n")
        newTask.target = self
        let addFolders = fileMenu.addItem(withTitle: "Add Workspace Folders…", action: #selector(addFolders), keyEquivalent: "o")
        addFolders.target = self
        fileMenu.addItem(.separator())
        let run = fileMenu.addItem(withTitle: "Send Message / Run Agents", action: #selector(runAgents), keyEquivalent: "\r")
        run.target = self
        file.submenu = fileMenu
        bar.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu
        bar.addItem(edit)
        let windows = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.submenu = windowMenu
        bar.addItem(windows)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = bar
    }
    @objc private func newTask() { store.newTask() }
    @objc private func addFolders() { store.addFolders() }
    @objc private func runAgents() { store.startRun() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(runAgents) { return store.canRun }
        if item.action == #selector(addFolders) { return store.loaded }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        Task {
            await store.shutdown()
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum ConductorApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(options: LaunchOptions())
        application.setActivationPolicy(.regular)
        application.appearance = NSAppearance(named: .darkAqua)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
