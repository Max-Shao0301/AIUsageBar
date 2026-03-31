import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class StatusBarController {

    // MARK: - Properties
    private let statusSymbolName = "brain.head.profile"
    private let statusItem: NSStatusItem
    private let popover:    NSPopover
    private let viewModel:  UsageViewModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init() {
        viewModel  = UsageViewModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover    = NSPopover()

        setupStatusItem()
        setupPopover()
        observeViewModel()
    }

    // MARK: - Setup: Status Item
    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image              = NSImage(systemSymbolName: statusSymbolName,
                                            accessibilityDescription: "AI Usage")
        button.image?.isTemplate  = true
        button.imagePosition      = .imageOnly
        button.title              = ""
        button.action             = #selector(handleClick(_:))
        button.target             = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Setup: Popover
    private func setupPopover() {
        popover.behavior            = .transient
        popover.animates            = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(viewModel: viewModel)
        )
    }

    // MARK: - Observe ViewModel → Update Menu Bar Text
    private func observeViewModel() {
        viewModel.$usageData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButtonLabel() }
            .store(in: &cancellables)

        viewModel.$codexUsageData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButtonLabel() }
            .store(in: &cancellables)

        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButtonLabel() }
            .store(in: &cancellables)
    }

    private func updateButtonLabel() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: statusSymbolName,
                               accessibilityDescription: "AI Usage")
        button.image?.isTemplate = true
    }

    // MARK: - Click Handler
    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            viewModel.refresh()
        }
    }

    // MARK: - Right-click Context Menu
    private func showContextMenu() {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "立即更新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let launchItem = NSMenuItem(title: "登入時自動啟動", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "結束 AIUsageBar",
                                  action: #selector(doQuit),
                                  keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = nil
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func doRefresh() {
        viewModel.refresh()
    }

    @objc private func doQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at Login

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            #if DEBUG
            print("[LaunchAtLogin] Configuration failed: \(error.localizedDescription)")
            #endif
        }
    }
}
