//
//  pulseApp.swift
//  pulse
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import SwiftUI
import SwiftData

@main
struct pulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        // Empty scene - we're using menu bar only
        Settings {
            EmptyView()
        }
    }
}
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: EventMonitor?
    private var workingHoursObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize GitHubService early to start fetching data at launch
        _ = GitHubService.shared

        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Pulse")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 550)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover

        // Sync popover appearance with system theme
        updatePopoverAppearance()

        // Observe system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        // Monitor for clicks outside the popover
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.closePopover()
            }
        }

        // Observe working hours status for icon changes
        workingHoursObservation = Task { @MainActor in
            let service = GitHubService.shared
            while !Task.isCancelled {
                let outsideHours = service.isOutsideWorkingHours
                if let button = statusItem?.button {
                    let iconName = outsideHours ? "moon.zzz" : "waveform.path.ecg"
                    button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Pulse")
                    button.image?.isTemplate = true
                }
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }

        // Hide the dock icon
        NSApp.setActivationPolicy(.accessory)

        // Listen for settings notification from the gear button in popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .openSettings,
            object: nil
        )
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                closePopover()
            } else {
                showPopover(relativeTo: button)
            }
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard let popover = popover else { return }
        updatePopoverAppearance()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor?.start()

        // Focus the popover window to enable keyboard input
        if let popoverWindow = popover.contentViewController?.view.window {
            popoverWindow.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        eventMonitor?.stop()
    }

    @objc func systemAppearanceChanged() {
        updatePopoverAppearance()
    }

    private func updatePopoverAppearance() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        popover?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    @objc func openSettings() {
        closePopover()
        SettingsWindowController.shared.show()
    }

    @objc func openAbout() {
        closePopover()
        SettingsWindowController.shared.show(tab: .about)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - OAuth URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if OAuthManager.shared.handleCallback(url: url) {
                // Bring app to front after OAuth callback
                NSApp.activate(ignoringOtherApps: true)
                // Show popover
                if let button = statusItem?.button {
                    showPopover(relativeTo: button)
                }
                break
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let showPRNotification = Notification.Name("showPRNotification")
}

// MARK: - Screen Detection Helper
extension NSScreen {
    /// Returns the screen containing the mouse cursor
    static var screenWithMouse: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        // Find screen containing the mouse pointer
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        // Fallback to main screen
        return NSScreen.main ?? NSScreen.screens.first!
    }
}

// MARK: - Full Screen PR Notification

class PRNotificationWindowController {
    static let shared = PRNotificationWindowController()

    private var window: NSWindow?
    private var autoCloseTimer: Timer?

    func show(for prs: [PullRequest]) {
        guard !prs.isEmpty else { return }

        // Cancel any existing timer
        autoCloseTimer?.invalidate()

        // Close existing window if any
        window?.close()

        // Create the full-screen notification view
        let notificationView = FullScreenPRNotificationView(
            prs: prs,
            isReminder: false,
            onOpen: { [weak self] pr in
                // Start watching this PR when user opens it
                GitHubService.shared.startWatching(pr: pr)
                if let url = URL(string: pr.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
                self?.dismiss()
            },
            onReviewLater: { [weak self] pr in
                // Just start watching, don't open the PR
                GitHubService.shared.startWatching(pr: pr)
                self?.dismiss()
            },
            onSnooze: { [weak self] pr, minutes in
                // Snooze - will remind after X minutes
                GitHubService.shared.snoozeNewPR(pr: pr, minutes: minutes)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        // Get the screen where the mouse is located
        let screen = NSScreen.screenWithMouse
        let screenFrame = screen.frame

        // Create borderless full-screen window
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = NSHostingController(rootView: notificationView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false

        // Set frame to cover the entire screen where mouse is
        window.setFrame(screenFrame, display: true)

        // Fade in
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 1
        }

        self.window = window

        // Auto-close after 15 seconds
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil

        guard let windowToClose = window else { return }
        window = nil

        // Simple immediate close - no animation to avoid crashes
        windowToClose.orderOut(nil)
    }

    func showReminder(for watchedPRs: [WatchedPR]) {
        guard !watchedPRs.isEmpty else { return }

        // Cancel any existing timer
        autoCloseTimer?.invalidate()

        // Close existing window if any
        window?.close()

        // Create the reminder notification view
        let notificationView = FullScreenPRNotificationView(
            prs: [],
            watchedPRs: watchedPRs,
            isReminder: true,
            onOpen: { [weak self] pr in
                if let url = URL(string: pr.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
                self?.dismiss()
            },
            onOpenWatched: { [weak self] watched in
                if let url = URL(string: watched.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            },
            onStopReminding: { [weak self] prId in
                GitHubService.shared.stopWatching(prId: prId)
                self?.dismiss()
            }
        )

        // Get the screen where the mouse is located
        let screen = NSScreen.screenWithMouse
        let screenFrame = screen.frame

        // Create borderless full-screen window
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = NSHostingController(rootView: notificationView)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false

        window.setFrame(screenFrame, display: true)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 1
        }

        self.window = window

        // Auto-close after 15 seconds
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(tab: SettingsTab = .account) {
        // If window already exists and is visible, bring it to front
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Close existing window if any
        window?.close()

        // Create settings view with initial tab
        let settingsView = SettingsWindowView(initialTab: tab, onClose: { [weak self] in
            self?.dismiss()
        })

        // Calculate window position (center of screen)
        let windowWidth: CGFloat = 450
        let windowHeight: CGFloat = 400
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let windowX = screenFrame.midX - windowWidth / 2
        let windowY = screenFrame.midY - windowHeight / 2

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        window.contentViewController = hostingController
        window.title = "Pulse Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))
        window.minSize = NSSize(width: windowWidth, height: windowHeight)
        window.center()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func dismiss() {
        window?.close()
        window = nil
    }

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct FullScreenPRNotificationView: View {
    let prs: [PullRequest]
    let watchedPRs: [WatchedPR]
    let isReminder: Bool
    let onOpen: (PullRequest) -> Void
    let onOpenWatched: (WatchedPR) -> Void
    let onReviewLater: ((PullRequest) -> Void)?
    let onSnooze: ((PullRequest, Int) -> Void)?  // PR and minutes to snooze
    let onDismiss: () -> Void
    let onStopReminding: ((Int) -> Void)?

    init(
        prs: [PullRequest] = [],
        watchedPRs: [WatchedPR] = [],
        isReminder: Bool = false,
        onOpen: @escaping (PullRequest) -> Void = { _ in },
        onOpenWatched: @escaping (WatchedPR) -> Void = { _ in },
        onReviewLater: ((PullRequest) -> Void)? = nil,
        onSnooze: ((PullRequest, Int) -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onStopReminding: ((Int) -> Void)? = nil
    ) {
        self.prs = prs
        self.watchedPRs = watchedPRs
        self.isReminder = isReminder
        self.onOpen = onOpen
        self.onOpenWatched = onOpenWatched
        self.onReviewLater = onReviewLater
        self.onSnooze = onSnooze
        self.onDismiss = onDismiss
        self.onStopReminding = onStopReminding
    }

    private var displayCount: Int {
        isReminder ? watchedPRs.count : prs.count
    }

    var body: some View {
        ZStack {
            // Dark overlay background (no tap to dismiss - use explicit button)
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            // Center content
            VStack(spacing: 40) {
                // Icon with animation
                Image(systemName: isReminder ? "clock.badge.exclamationmark" : "bell.badge.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(isReminder ? .yellow : .orange)
                    .symbolEffect(.pulse, options: .repeating)

                // Main text
                VStack(spacing: 16) {
                    Text(headerText)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)

                    Text(subtitleText)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }

                // PR cards
                VStack(spacing: 12) {
                    if isReminder {
                        ForEach(watchedPRs.prefix(3)) { watched in
                            WatchedPRNotificationCard(
                                watched: watched,
                                onOpen: onOpenWatched,
                                onStopReminding: onStopReminding
                            )
                        }
                        if watchedPRs.count > 3 {
                            Text("+ \(watchedPRs.count - 3) more")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 8)
                        }
                    } else {
                        ForEach(prs.prefix(3)) { pr in
                            PRNotificationCard(pr: pr, onOpen: onOpen)
                        }
                        if prs.count > 3 {
                            Text("+ \(prs.count - 3) more")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 8)
                        }
                    }
                }
                .frame(maxWidth: 600)

                // Actions
                HStack(spacing: 20) {
                    Button(action: onDismiss) {
                        Text("Dismiss")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)

                    if !isReminder && prs.count == 1, let pr = prs.first {
                        // Open PR button
                        Button(action: { onOpen(pr) }) {
                            Text("Open PR")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 14)
                                .background(Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        // Snooze 5 min button
                        if let onSnooze = onSnooze {
                            Button(action: { onSnooze(pr, 5) }) {
                                Text("5 min")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 14)
                                    .background(Color.orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.return)
                        }
                    }

                    if isReminder && watchedPRs.count == 1, let watched = watchedPRs.first {
                        Button(action: { onOpenWatched(watched) }) {
                            Text("Open PR")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return)
                    }
                }
                .padding(.top, 20)

                // Hint
                Text("Press Escape or click Dismiss to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 20)
            }
            .padding(60)
        }
    }

    private var headerText: String {
        if isReminder {
            return watchedPRs.count == 1 ? "Review Reminder" : "\(watchedPRs.count) Review Reminders"
        } else {
            return prs.count == 1 ? "New PR Review Request" : "\(prs.count) New PR Review Requests"
        }
    }

    private var subtitleText: String {
        if isReminder {
            if watchedPRs.count == 1, let watched = watchedPRs.first {
                let minutes = Int(Date().timeIntervalSince(watched.startedWatchingAt) / 60)
                return "You opened this \(minutes) minute\(minutes == 1 ? "" : "s") ago"
            }
            return "PRs you opened but haven't reviewed yet"
        } else {
            return "Pull request\(prs.count == 1 ? "" : "s") awaiting your review"
        }
    }
}

struct PRNotificationCard: View {
    let pr: PullRequest
    let onOpen: (PullRequest) -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: { onOpen(pr) }) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pr.repository)
                        .font(.subheadline)
                        .foregroundStyle(.blue)

                    Text(pr.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 12) {
                        Label("#\(pr.number)", systemImage: "number")
                        Label(pr.user.login, systemImage: "person.fill")
                        if pr.draft {
                            Text("DRAFT")
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray)
                                .clipShape(Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct WatchedPRNotificationCard: View {
    let watched: WatchedPR
    let onOpen: (WatchedPR) -> Void
    let onStopReminding: ((Int) -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { onOpen(watched) }) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(watched.repository)
                            .font(.subheadline)
                            .foregroundStyle(.blue)

                        Text(watched.title)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 12) {
                            Label("#\(watched.prNumber)", systemImage: "number")
                            Label(watched.authorLogin, systemImage: "person.fill")

                            let minutes = Int(Date().timeIntervalSince(watched.startedWatchingAt) / 60)
                            Label("\(minutes)m ago", systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    }

                    Spacer()

                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)

            if let onStopReminding = onStopReminding {
                Button(action: { onStopReminding(watched.id) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Stop reminding about this PR")
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovered ? 0.15 : 0.1))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Event Monitor
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void
    
    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }
    
    deinit {
        stop()
    }
    
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }
    
    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}


