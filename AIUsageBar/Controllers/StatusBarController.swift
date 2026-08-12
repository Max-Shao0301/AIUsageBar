import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class StatusBarController {

    // MARK: - Properties
    private let statusSymbolName = "brain.head.profile"
    private let launchAtLoginRegistrationStampKey = "LaunchAtLoginRegistrationStamp"
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

        viewModel.$antigravityUsageData
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

        let repairLaunchItem = NSMenuItem(title: "修復登入啟動", action: #selector(repairLaunchAtLoginManually), keyEquivalent: "")
        repairLaunchItem.target = self
        menu.addItem(repairLaunchItem)

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

    func repairLaunchAtLoginRegistrationIfNeededOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.repairLaunchAtLoginRegistrationIfNeeded(force: false)
        }
    }

    @objc private func repairLaunchAtLoginManually() {
        repairLaunchAtLoginRegistrationIfNeeded(force: true)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(forKey: launchAtLoginRegistrationStampKey)
            } else {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(currentLaunchAtLoginRegistrationStamp,
                                          forKey: launchAtLoginRegistrationStampKey)
            }
        } catch {
            #if DEBUG
            print("[LaunchAtLogin] Configuration failed: \(error.localizedDescription)")
            #endif
        }
    }

    private var currentLaunchAtLoginRegistrationStamp: String {
        let bundlePath = Bundle.main.bundleURL.path
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(bundlePath)|\(shortVersion)|\(buildVersion)"
    }

    private func repairLaunchAtLoginRegistrationIfNeeded(force: Bool) {
        let service = SMAppService.mainApp
        let storedStamp = UserDefaults.standard.string(forKey: launchAtLoginRegistrationStampKey)
        let currentStamp = currentLaunchAtLoginRegistrationStamp

        let shouldRepair: Bool
        switch service.status {
        case .enabled:
            shouldRepair = force || storedStamp != currentStamp
        case .notFound:
            shouldRepair = force || storedStamp != nil
        case .requiresApproval, .notRegistered:
            shouldRepair = force
        @unknown default:
            shouldRepair = force
        }

        guard shouldRepair else { return }

        let stampKey = launchAtLoginRegistrationStampKey
        service.unregister { _ in
            DispatchQueue.main.async {
                do {
                    try service.register()
                    UserDefaults.standard.set(currentStamp, forKey: stampKey)
                    #if DEBUG
                    print("[LaunchAtLogin] Repaired registration")
                    #endif
                } catch {
                    #if DEBUG
                    print("[LaunchAtLogin] Repair failed: \(error.localizedDescription)")
                    #endif
                }
            }
        }
    }
}
