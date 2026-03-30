import AppKit
import SwiftUI
import Combine

final class StatusBarController {

    // MARK: - Properties
    private let statusItem: NSStatusItem
    private let popover:    NSPopover
    private let viewModel:  UsageViewModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init
    init() {
        viewModel  = UsageViewModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover    = NSPopover()

        setupStatusItem()
        setupPopover()
        observeViewModel()
    }

    // MARK: - Setup: Status Item
    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image              = NSImage(systemSymbolName: "sparkle",
                                            accessibilityDescription: "Claude Usage")
        button.image?.isTemplate  = true
        button.imagePosition      = .imageLeft
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

    // MARK: - Observe ViewModel → 更新 Menu Bar 文字
    private func observeViewModel() {
        viewModel.$usageData
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
        if viewModel.isLoading && viewModel.usageData == nil {
            button.title = " ..."
        } else if viewModel.usageData != nil {
            let pct = Int(viewModel.maxUtilization)
            button.title = " \(pct)%"

            // 高用量時換警告色 icon
            if pct >= 80 {
                button.image = NSImage(systemSymbolName: "exclamationmark.circle",
                                       accessibilityDescription: "High Usage")
            } else {
                button.image = NSImage(systemSymbolName: "sparkle",
                                       accessibilityDescription: "Claude Usage")
            }
            button.image?.isTemplate = true
        } else {
            button.title = ""
        }
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

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "結束 AIUsageBar",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func doRefresh() {
        viewModel.refresh()
    }
}
