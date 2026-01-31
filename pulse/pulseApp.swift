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
    private var contextMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize GitHubService early to start fetching data at launch
        _ = GitHubService.shared

        // Create the status item in the menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Pulse")
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Create the context menu for right-click
        contextMenu = NSMenu()
        contextMenu?.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        contextMenu?.addItem(NSMenuItem.separator())
        contextMenu?.addItem(NSMenuItem(title: "Quit Pulse", action: #selector(quitApp), keyEquivalent: "q"))

        // Create the popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 550)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover

        // Monitor for clicks outside the popover
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.closePopover()
            }
        }

        // Hide the dock icon and main window
        NSApp.setActivationPolicy(.accessory)

        // Listen for settings notification from the gear button in popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .openSettings,
            object: nil
        )
    }

    @objc func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Show context menu on right-click
            if let button = statusItem?.button, let menu = contextMenu {
                statusItem?.menu = menu
                button.performClick(nil)
                statusItem?.menu = nil  // Reset so left-click works again
            }
        } else {
            // Toggle popover on left-click
            togglePopover()
        }
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

    @objc func openSettings() {
        // Close the popover and show settings in independent window
        closePopover()
        SettingsWindowController.shared.show()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard let popover = popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor?.start()
    }

    private func closePopover() {
        popover?.performClose(nil)
        eventMonitor?.stop()
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    static let showPRNotification = Notification.Name("showPRNotification")
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
        let notificationView = FullScreenPRNotificationView(prs: prs) { [weak self] pr in
            if let url = URL(string: pr.htmlURL) {
                NSWorkspace.shared.open(url)
            }
            self?.dismiss()
        } onDismiss: { [weak self] in
            self?.dismiss()
        }

        // Get the screen where the mouse is located, or main screen as fallback
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first!
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

        // Set frame to cover the entire screen
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
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // If window already exists and is visible, bring it to front
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Close existing window if any
        window?.close()

        // Create settings view
        let settingsView = SettingsWindowView(onClose: { [weak self] in
            self?.dismiss()
        })

        // Calculate window position (center of screen)
        let windowWidth: CGFloat = 380
        let windowHeight: CGFloat = 480
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

        window.contentViewController = NSHostingController(rootView: settingsView)
        window.title = "Pulse Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
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
    let onOpen: (PullRequest) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dark overlay background
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            // Center content
            VStack(spacing: 40) {
                // Bell icon with animation
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)

                // Main text
                VStack(spacing: 16) {
                    Text(prs.count == 1 ? "New PR Review Request" : "\(prs.count) New PR Review Requests")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Pull request\(prs.count == 1 ? "" : "s") awaiting your review")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }

                // PR cards
                VStack(spacing: 12) {
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

                    if prs.count == 1, let pr = prs.first {
                        Button(action: { onOpen(pr) }) {
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
                Text("Press Escape or click anywhere to dismiss")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 20)
            }
            .padding(60)
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


