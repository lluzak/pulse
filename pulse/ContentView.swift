//
//  ContentView.swift
//  pulse
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import SwiftUI

struct ContentView: View {
    var gitHubService = GitHubService.shared

    var body: some View {
        Group {
            if gitHubService.isCheckingAuth {
                // Loading screen while validating stored token
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)

                    Text("Pulse")
                        .font(.title)
                        .fontWeight(.bold)

                    ProgressView()
                        .padding(.top, 8)

                    Text("Connecting to GitHub...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if gitHubService.isAuthenticated {
                PRListView(gitHubService: gitHubService)
            } else {
                GitHubAuthView(gitHubService: gitHubService)
            }
        }
        .frame(width: 400, height: 550)
    }
}

struct GitHubAuthView: View {
    @Bindable var gitHubService: GitHubService
    @State private var tokenInput: String = ""
    @State private var isAuthenticating: Bool = false
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 12) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("Connect to GitHub")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Sign in to view your pending PRs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Personal Access Token")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                SecureField("Enter your GitHub token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isAuthenticating)
                
                Button(action: authenticate) {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "key.fill")
                        }
                        Text(isAuthenticating ? "Authenticating..." : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tokenInput.isEmpty || isAuthenticating)
                
                if let error = gitHubService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
            
            VStack(spacing: 8) {
                Text("How to get a token:")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Go to GitHub Settings → Developer settings")
                    Text("2. Select Personal access tokens → Fine-grained")
                    Text("3. Generate new token with repo access")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                
                Button("Open GitHub Settings") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens")!)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }
    
    private func authenticate() {
        isAuthenticating = true
        Task {
            await gitHubService.authenticate(token: tokenInput)
            isAuthenticating = false
            if gitHubService.isAuthenticated {
                tokenInput = ""
            }
        }
    }
}

struct PRListView: View {
    @Bindable var gitHubService: GitHubService
    @State private var selectedTab: PRTab = .awaitingReview
    @State private var showingSettings = false
    @State private var showingAbout = false

    enum PRTab: String, CaseIterable {
        case awaitingReview = "Awaiting Review"
        case involved = "Involved"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    if let user = gitHubService.currentUser {
                        AsyncImage(url: URL(string: user.avatarURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name ?? user.login)
                                .font(.headline)
                            Text("@\(user.login)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: {
                        Task { await gitHubService.fetchAllPRs() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(gitHubService.isLoading)

                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Picker("", selection: $selectedTab) {
                    ForEach(PRTab.allCases, id: \.self) { tab in
                        Text(tabLabel(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()

            // Per-tab loading and content
            tabContent
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(gitHubService: gitHubService, isPresented: $showingSettings)
        }
        .sheet(isPresented: $showingAbout) {
            AboutView(isPresented: $showingAbout)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showingAbout = true
        }
        .background {
            // Hidden button for Cmd+R keyboard shortcut
            Button("") {
                Task { await gitHubService.fetchAllPRs() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        let isLoading = selectedTab == .awaitingReview ? gitHubService.isLoadingAwaiting : gitHubService.isLoadingInvolved
        let hasLoaded = selectedTab == .awaitingReview ? gitHubService.hasLoadedAwaiting : gitHubService.hasLoadedInvolved
        let prs = selectedTab == .awaitingReview ? gitHubService.awaitingReviewPRs : gitHubService.involvedPRs

        if !hasLoaded {
            // Haven't loaded yet - show loading state
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading PRs...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if prs.isEmpty {
            // Loaded but no PRs
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .padding(.bottom, 8)
                }
                Image(systemName: selectedTab == .awaitingReview ? "checkmark.circle.fill" : "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(selectedTab == .awaitingReview ? .green : .gray)

                Text(selectedTab == .awaitingReview ? "All caught up!" : "No PRs")
                    .font(.headline)

                Text(selectedTab == .awaitingReview ? "No PRs awaiting your review" : "No PRs you're involved with")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else {
            // Have PRs to display
            ScrollView {
                if isLoading {
                    ProgressView()
                        .padding(8)
                }
                LazyVStack(spacing: 0) {
                    ForEach(prs) { pr in
                        PRRowView(pr: pr, gitHubService: gitHubService)
                        Divider()
                    }
                }
            }
        }
    }

    private func tabLabel(for tab: PRTab) -> String {
        let count = prCount(for: tab) ?? 0
        return count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue
    }

    private func prCount(for tab: PRTab) -> Int? {
        switch tab {
        case .awaitingReview:
            return gitHubService.awaitingReviewPRs.count
        case .involved:
            return gitHubService.involvedPRs.count
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Bindable var gitHubService: GitHubService
    @Binding var isPresented: Bool

    // Local state for polling interval (in minutes for the slider)
    @State private var pollingMinutes: Double = 5

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Settings content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Polling Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Refresh Interval", systemImage: "clock.arrow.circlepath")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Every \(Int(pollingMinutes)) minute\(Int(pollingMinutes) == 1 ? "" : "s")")
                                    .font(.subheadline)
                                Spacer()
                            }

                            Slider(value: $pollingMinutes, in: 1...30, step: 1) { editing in
                                if !editing {
                                    gitHubService.pollingInterval = pollingMinutes * 60
                                }
                            }

                            Toggle("Auto-refresh enabled", isOn: $gitHubService.isPollingEnabled)
                                .font(.subheadline)
                        }
                    }

                    Divider()

                    // Notifications Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Notifications", systemImage: "bell.fill")
                            .font(.headline)

                        HStack {
                            Text("Status:")
                                .font(.subheadline)
                            Text(notificationStatusText)
                                .font(.subheadline)
                                .foregroundStyle(notificationStatusColor)
                        }

                        if gitHubService.notificationStatus == .denied {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.subheadline)
                        }

                        Button("Test Notification") {
                            testNotification()
                        }
                        .font(.subheadline)
                    }

                    Divider()

                    // Repository Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Repositories", systemImage: "folder.fill")
                            .font(.headline)

                        Toggle("Monitor all accessible repositories", isOn: $gitHubService.monitorAllRepositories)
                            .font(.subheadline)

                        if !gitHubService.monitorAllRepositories {
                            Text("Specific repository filtering coming soon...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // Account Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Account", systemImage: "person.circle.fill")
                            .font(.headline)

                        if let user = gitHubService.currentUser {
                            HStack {
                                AsyncImage(url: URL(string: user.avatarURL)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray
                                }
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())

                                Text("@\(user.login)")
                                    .font(.subheadline)

                                Spacer()

                                Button("Sign Out") {
                                    gitHubService.signOut()
                                    isPresented = false
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer with Quit button
            HStack {
                Text("Pulse v1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    // Close sheet first, then quit after a brief delay
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("Quit Pulse")
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 350, height: 450)
        .onAppear {
            pollingMinutes = gitHubService.pollingInterval / 60
        }
    }

    private func testNotification() {
        let mockPR = PullRequest(
            id: 99999,
            number: 123,
            title: "Add new feature for user authentication",
            body: "This PR adds OAuth2 support",
            htmlURL: "https://github.com/octocat/Hello-World/pull/123",
            state: "open",
            createdAt: "2024-01-29T10:00:00Z",
            updatedAt: "2024-01-29T12:00:00Z",
            user: PRUser(login: "octocat", avatarURL: "https://github.com/images/error/octocat_happy.gif"),
            draft: false,
            head: PRBranch(ref: "feature-auth", repo: PRRepository(name: "Hello-World", fullName: "octocat/Hello-World")),
            base: PRBranch(ref: "main", repo: PRRepository(name: "Hello-World", fullName: "octocat/Hello-World")),
            additions: 150,
            deletions: 23,
            changedFiles: 8
        )
        // Send both full-screen and system notification
        gitHubService.sendNotification(for: [mockPR])
    }

    private var notificationStatusText: String {
        switch gitHubService.notificationStatus {
        case .authorized: return "Enabled"
        case .denied: return "Denied"
        case .notDetermined: return "Not Set"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        }
    }

    private var notificationStatusColor: Color {
        switch gitHubService.notificationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        }
    }
}

// MARK: - About View

struct AboutView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("About")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            VStack(spacing: 20) {
                Spacer()

                // App Icon
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                // App Name & Version
                VStack(spacing: 4) {
                    Text("Pulse")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Version 1.0")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Description
                Text("A lightweight menu bar app for tracking\nGitHub Pull Requests awaiting your review.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Spacer()

                // Links
                VStack(spacing: 12) {
                    Button(action: {
                        if let url = URL(string: "https://github.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        Label("View on GitHub", systemImage: "link")
                    }
                    .buttonStyle(.link)
                }

                Spacer()

                // Copyright
                Text("Made with Swift & SwiftUI")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .frame(width: 300, height: 350)
    }
}

struct PRRowView: View {
    let pr: PullRequest
    let gitHubService: GitHubService
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            gitHubService.openPRInBrowser(pr)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Text(pr.repository)
                        .font(.caption)
                        .foregroundStyle(.tint)
                    
                    Spacer()
                    
                    if pr.draft {
                        Text("DRAFT")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .quaternaryLabelColor))
                            .clipShape(Capsule())
                    }
                }
                
                Text(pr.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                
                HStack(spacing: 12) {
                    Label("#\(pr.number)", systemImage: "number")
                        .font(.caption2)
                    
                    Label(pr.user.login, systemImage: "person.fill")
                        .font(.caption2)
                    
                    if let additions = pr.additions, let deletions = pr.deletions {
                        HStack(spacing: 4) {
                            Text("+\(additions)")
                                .foregroundStyle(.green)
                            Text("-\(deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.caption2)
                        .fontWeight(.medium)
                    }
                    
                    Spacer()
                    
                    Text(pr.updatedDate.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

#Preview {
    ContentView()
}

