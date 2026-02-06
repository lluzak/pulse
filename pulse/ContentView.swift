//
//  ContentView.swift
//  pulse
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import SwiftUI
import Combine

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
    @State private var showToken: Bool = false
    @State private var showTokenInput: Bool = false

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

            VStack(spacing: 16) {
                // Primary: OAuth Sign In
                Button(action: startOAuth) {
                    HStack {
                        if gitHubService.isOAuthInProgress {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Waiting for GitHub...")
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("Sign in with GitHub")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(gitHubService.isOAuthInProgress || isAuthenticating)

                if gitHubService.isOAuthInProgress {
                    Button("Cancel") {
                        gitHubService.cancelOAuth()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                // Secondary: Token fallback
                Button(action: { withAnimation { showTokenInput.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showTokenInput ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Use personal access token")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(gitHubService.isOAuthInProgress)

                if showTokenInput {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if showToken {
                                TextField("Enter your GitHub token", text: $tokenInput)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isAuthenticating)
                            } else {
                                SecureField("Enter your GitHub token", text: $tokenInput)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isAuthenticating)
                            }

                            Button(action: { showToken.toggle() }) {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(isAuthenticating)
                        }

                        Button(action: authenticateWithToken) {
                            HStack {
                                if isAuthenticating {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "key.fill")
                                }
                                Text(isAuthenticating ? "Authenticating..." : "Sign In with Token")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(tokenInput.isEmpty || isAuthenticating)

                        Button("How to get a token") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens")!)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    .padding(.top, 8)
                }

                if let error = gitHubService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func startOAuth() {
        gitHubService.errorMessage = nil
        gitHubService.startOAuthFlow()
    }

    private func authenticateWithToken() {
        isAuthenticating = true
        gitHubService.errorMessage = nil
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
    @State private var selectedTab: PRTab = .myPRs
    @FocusState private var isFocused: Bool
    @State private var focusSink: String = ""

    enum PRTab: String, CaseIterable {
        case myPRs = "My PRs"
        case awaitingReview = "Awaiting Review"
        case involved = "Involved"
    }

    var body: some View {
        ZStack {
            // Invisible TextField to capture focus and enable keyboard events
            TextField("", text: $focusSink)
                .textFieldStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focused($isFocused)

            mainContent
        }
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }

    private var mainContent: some View {
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

            Divider()

            // Footer with settings and quit
            HStack {
                Button(action: {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    private var currentIsLoading: Bool {
        switch selectedTab {
        case .awaitingReview: return gitHubService.isLoadingAwaiting
        case .involved: return gitHubService.isLoadingInvolved
        case .myPRs: return gitHubService.isLoadingMyPRs
        }
    }

    private var currentHasLoaded: Bool {
        switch selectedTab {
        case .awaitingReview: return gitHubService.hasLoadedAwaiting
        case .involved: return gitHubService.hasLoadedInvolved
        case .myPRs: return gitHubService.hasLoadedMyPRs
        }
    }

    private var currentPRs: [PullRequest] {
        switch selectedTab {
        case .awaitingReview: return gitHubService.awaitingReviewPRs
        case .involved: return gitHubService.involvedPRs
        case .myPRs: return gitHubService.myPRs
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if !currentHasLoaded {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading PRs...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxHeight: .infinity)
        } else if currentPRs.isEmpty {
            VStack(spacing: 12) {
                if currentIsLoading {
                    ProgressView()
                        .padding(.bottom, 8)
                }

                if let error = gitHubService.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Error loading PRs")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(emptyStateColor)

                    Text(emptyStateTitle)
                        .font(.headline)

                    Text(emptyStateSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if selectedTab == .myPRs {
                    MyPRsFilterBar(gitHubService: gitHubService)
                }

                ScrollView {
                    if currentIsLoading && currentPRs.isEmpty {
                        ProgressView()
                            .padding(8)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(currentPRs) { pr in
                            PRRowView(pr: pr, gitHubService: gitHubService, showReviewStatus: selectedTab == .myPRs || selectedTab == .awaitingReview)
                            Divider()
                        }

                        // Infinite scroll trigger for My PRs
                        if selectedTab == .myPRs && gitHubService.myPRsHasMore {
                            if gitHubService.isLoadingMoreMyPRs {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            } else {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        Task {
                                            await gitHubService.loadMoreMyPRs()
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyStateIcon: String {
        switch selectedTab {
        case .awaitingReview: return "checkmark.circle.fill"
        case .involved: return "tray"
        case .myPRs: return "doc.text"
        }
    }

    private var emptyStateColor: Color {
        switch selectedTab {
        case .awaitingReview: return .green
        case .involved: return .gray
        case .myPRs: return .gray
        }
    }

    private var emptyStateTitle: String {
        switch selectedTab {
        case .awaitingReview: return "All caught up!"
        case .involved: return "No PRs"
        case .myPRs: return "No PRs"
        }
    }

    private var emptyStateSubtitle: String {
        switch selectedTab {
        case .awaitingReview: return "No PRs awaiting your review"
        case .involved: return "No PRs you're involved with"
        case .myPRs: return "You haven't created any PRs"
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
        case .myPRs:
            // Always show open PR count regardless of filter
            return gitHubService.myOpenPRsCount
        }
    }
}

// MARK: - My PRs Filter Bar

struct MyPRsFilterBar: View {
    @Bindable var gitHubService: GitHubService

    var body: some View {
        HStack {
            Picker("", selection: $gitHubService.myPRsStateFilter) {
                ForEach(PRStateFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: gitHubService.myPRsStateFilter) { _, _ in
                Task { await gitHubService.fetchMyPRs() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: - Settings Window View (Independent Window)

struct SettingsWindowView: View {
    var gitHubService = GitHubService.shared
    let initialTab: SettingsTab
    let onClose: () -> Void
    @State private var selectedTab: SettingsTab = .account
    @State private var pollingMinutes: Double = 5

    init(initialTab: SettingsTab = .account, onClose: @escaping () -> Void) {
        self.initialTab = initialTab
        self.onClose = onClose
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(tab: tab, isSelected: selectedTab == tab) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content with fixed height to prevent shifts
            ZStack {
                AccountWindowTabView(gitHubService: gitHubService, onClose: onClose)
                    .opacity(selectedTab == .account ? 1 : 0)
                RepositoriesTabView(gitHubService: gitHubService)
                    .opacity(selectedTab == .repositories ? 1 : 0)
                NotificationsTabView(gitHubService: gitHubService, pollingMinutes: $pollingMinutes)
                    .opacity(selectedTab == .notifications ? 1 : 0)
                AboutTabView()
                    .opacity(selectedTab == .about ? 1 : 0)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Footer
            HStack {
                Text("Pulse v1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onClose()
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
        .onAppear {
            pollingMinutes = gitHubService.pollingInterval / 60
        }
    }
}

// Account tab for window (uses onClose instead of isPresented binding)
struct AccountWindowTabView: View {
    @Bindable var gitHubService: GitHubService
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let user = gitHubService.currentUser {
                    // User profile card with sign out button
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: user.avatarURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name ?? user.login)
                                .font(.headline)
                            Text("@\(user.login)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            gitHubService.signOut()
                            onClose()
                        }) {
                            Text("Sign Out")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }
                    .padding()
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }
}

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable {
    case account = "Account"
    case repositories = "Repositories"
    case notifications = "Notifications"
    case about = "About"

    var icon: String {
        switch self {
        case .account: return "person.circle.fill"
        case .repositories: return "folder.fill"
        case .notifications: return "bell.fill"
        case .about: return "info.circle.fill"
        }
    }
}

struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20))
                Text(tab.rawValue)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Repositories Tab

struct RepositoriesTabView: View {
    @Bindable var gitHubService: GitHubService
    @State private var searchText: String = ""

    var filteredRepositories: [GitHubRepository] {
        if searchText.isEmpty {
            return gitHubService.availableRepositories
        }
        return gitHubService.availableRepositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle for all repos
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Monitor all accessible repositories", isOn: $gitHubService.monitorAllRepositories)
                    .padding(.horizontal)
                    .padding(.top)

                if gitHubService.monitorAllRepositories {
                    Text("Pulse will check for PRs across all repositories you have access to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }

            if !gitHubService.monitorAllRepositories {
                Divider()
                    .padding(.top, 12)

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search repositories...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.top, 12)

                // Repository list
                if gitHubService.isLoadingRepositories {
                    VStack {
                        ProgressView()
                        Text("Loading repositories...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if gitHubService.availableRepositories.isEmpty {
                    VStack(spacing: 8) {
                        Text("No repositories found")
                            .font(.subheadline)
                        Button("Load Repositories") {
                            Task { await gitHubService.fetchRepositories() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredRepositories) { repo in
                                RepositoryRow(
                                    repo: repo,
                                    isSelected: gitHubService.monitoredRepositories.contains(repo.fullName),
                                    onToggle: { gitHubService.toggleRepository(repo.fullName) }
                                )
                                Divider()
                            }
                        }
                    }
                    .padding(.top, 8)
                }

                // Selected count
                if !gitHubService.monitoredRepositories.isEmpty {
                    HStack {
                        Text("\(gitHubService.monitoredRepositories.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear All") {
                            gitHubService.monitoredRepositories.removeAll()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            if !gitHubService.monitorAllRepositories && gitHubService.availableRepositories.isEmpty {
                Task { await gitHubService.fetchRepositories() }
            }
        }
        .onChange(of: gitHubService.monitorAllRepositories) { _, newValue in
            if !newValue && gitHubService.availableRepositories.isEmpty {
                Task { await gitHubService.fetchRepositories() }
            }
        }
    }
}

struct RepositoryRow: View {
    let repo: GitHubRepository
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.system(size: 18))

                AsyncImage(url: URL(string: repo.owner.avatarURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.gray
                }
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.fullName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                            .font(.caption2)
                        Text(repo.isPrivate ? "Private" : "Public")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notifications Tab

struct NotificationsTabView: View {
    @Bindable var gitHubService: GitHubService
    @Binding var pollingMinutes: Double
    @State private var reminderMinutes: Double = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Notification status
                VStack(alignment: .leading, spacing: 12) {
                    Text("System Notifications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Status:")
                        Text(notificationStatusText)
                            .foregroundStyle(notificationStatusColor)
                    }

                    if gitHubService.notificationStatus == .denied {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }

                    Button("Test Notification") {
                        testNotification()
                    }
                }

                Divider()

                // Polling settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Auto-Refresh")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Enable auto-refresh", isOn: $gitHubService.isPollingEnabled)

                    Text("Automatically checks GitHub for new PRs awaiting your review and shows a notification when new ones appear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if gitHubService.isPollingEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Refresh every \(Int(pollingMinutes)) minute\(Int(pollingMinutes) == 1 ? "" : "s")")
                                .font(.caption)

                            Slider(value: $pollingMinutes, in: 1...30, step: 1) { editing in
                                if !editing {
                                    gitHubService.pollingInterval = pollingMinutes * 60
                                }
                            }
                        }
                    }
                }

                Divider()

                // Review Reminders section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review Reminders")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Enable review reminders", isOn: $gitHubService.isReminderEnabled)

                    Text("When you click \"Open PR\" on a notification, Pulse tracks it and reminds you until you approve. If you request changes or comment, reminders pause until the author responds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if gitHubService.isReminderEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remind every \(Int(reminderMinutes)) minutes")
                                .font(.caption)

                            Slider(value: $reminderMinutes, in: 5...60, step: 5) { editing in
                                if !editing {
                                    gitHubService.reminderInterval = reminderMinutes * 60
                                }
                            }
                        }

                        if !gitHubService.watchedPRs.isEmpty {
                            HStack {
                                Text("Watching \(gitHubService.watchedPRs.count) PR\(gitHubService.watchedPRs.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear All") {
                                    gitHubService.clearAllWatchedPRs()
                                }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                }

                // Dismissed PRs section
                if !gitHubService.dismissedPRIds.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Dismissed PRs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("\(gitHubService.dismissedPRIds.count) PR\(gitHubService.dismissedPRIds.count == 1 ? "" : "s") hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restore All") {
                                gitHubService.clearAllDismissedPRs()
                                Task { await gitHubService.fetchAllPRs() }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }

                        Text("Right-click on any PR to dismiss it. Dismissed PRs won't appear in your list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                // My PRs Notifications section
                VStack(alignment: .leading, spacing: 12) {
                    Text("My PRs Notifications")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Get notified about activity on pull requests you created.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Approvals", isOn: $gitHubService.myPRNotificationSettings.notifyOnApproval)
                        Toggle("Changes Requested", isOn: $gitHubService.myPRNotificationSettings.notifyOnChangesRequested)
                        Toggle("Review Comments", isOn: $gitHubService.myPRNotificationSettings.notifyOnReviewComment)
                        Toggle("Comments", isOn: $gitHubService.myPRNotificationSettings.notifyOnComment)
                        Toggle("CI Failures", isOn: $gitHubService.myPRNotificationSettings.notifyOnCheckFailure)
                        Toggle("CI Success", isOn: $gitHubService.myPRNotificationSettings.notifyOnCheckSuccess)
                        Toggle("Mentions", isOn: $gitHubService.myPRNotificationSettings.notifyOnMention)
                        Toggle("Merged", isOn: $gitHubService.myPRNotificationSettings.notifyOnMerge)
                        Toggle("Merge Conflicts", isOn: $gitHubService.myPRNotificationSettings.notifyOnConflict)
                    }
                    .font(.subheadline)

                    Divider()
                        .padding(.vertical, 4)

                    Toggle("Batch notifications", isOn: $gitHubService.myPRNotificationSettings.batchNotifications)
                        .font(.subheadline)

                    Text("When enabled, notifications are grouped and sent once per poll cycle instead of immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .onAppear {
            reminderMinutes = gitHubService.reminderInterval / 60
        }
    }

    private func testNotification() {
        gitHubService.sendTestNotification()
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

// MARK: - About Tab

struct AboutTabView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            VStack(spacing: 4) {
                Text("Pulse")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Version 1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("A lightweight menu bar app for tracking\nGitHub Pull Requests awaiting your review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            Spacer()

            Button(action: {
                if let url = URL(string: "https://github.com") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("View on GitHub", systemImage: "link")
            }
            .buttonStyle(.link)

            Spacer()

            Text("Made with Swift & SwiftUI")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

// MARK: - Review Status Badge

struct ReviewStatusBadge: View {
    let summary: PRReviewSummary

    private var statusColor: Color {
        if summary.changesRequestedCount > 0 {
            return .red
        } else if summary.approvedCount > 0 {
            return .green
        } else if summary.commentedCount > 0 {
            return .yellow
        }
        return .gray
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(summary.displayText)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct PRRowView: View {
    let pr: PullRequest
    let gitHubService: GitHubService
    var showReviewStatus: Bool = false
    @State private var reviewSummary: PRReviewSummary?
    @State private var isHovered = false
    @State private var now = Date()

    // Timer to update countdown
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Get watched PR info if this PR is being watched
    private var watchedPR: WatchedPR? {
        gitHubService.watchedPRs.first { $0.id == pr.id }
    }

    // Calculate next reminder time
    private var nextReminderDate: Date? {
        guard let watched = watchedPR else { return nil }

        // If snoozed, that's the next reminder time
        if let snoozedUntil = watched.snoozedUntil, snoozedUntil > now {
            return snoozedUntil
        }

        // Otherwise, calculate based on start time and interval
        let interval = gitHubService.reminderInterval
        let startTime = watched.startedWatchingAt
        let timeSinceStart = now.timeIntervalSince(startTime)

        // If we haven't passed the first interval yet
        if timeSinceStart < interval {
            return startTime.addingTimeInterval(interval)
        }

        // Calculate next interval
        let intervalsPassed = floor(timeSinceStart / interval)
        return startTime.addingTimeInterval((intervalsPassed + 1) * interval)
    }

    // Format countdown string
    private var countdownText: String? {
        guard let nextReminder = nextReminderDate else { return nil }
        let remaining = nextReminder.timeIntervalSince(now)
        if remaining <= 0 { return "soon" }

        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

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

                    // Show review status for My PRs tab
                    if showReviewStatus, let summary = reviewSummary {
                        ReviewStatusBadge(summary: summary)
                    }

                    // Show reminder countdown if watching
                    if let countdown = countdownText {
                        HStack(spacing: 3) {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                            Text(countdown)
                                .font(.caption2)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                    }

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

                    // Show merged badge
                    if pr.mergedAt != nil {
                        Text("MERGED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .clipShape(Capsule())
                    } else if pr.state == "closed" {
                        Text("CLOSED")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
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
                    
                    Text(pr.updatedDate.relativeTimeString())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onReceive(timer) { _ in
            now = Date()
        }
        .task {
            if showReviewStatus {
                await loadReviewSummary()
            }
        }
        .contextMenu {
            Button(action: {
                gitHubService.openPRInBrowser(pr)
            }) {
                Label("Open in Browser", systemImage: "safari")
            }

            Divider()

            if watchedPR != nil {
                Button(action: {
                    gitHubService.stopWatching(prId: pr.id)
                }) {
                    Label("Stop Reminding", systemImage: "bell.slash")
                }
            }

            Button(role: .destructive, action: {
                gitHubService.dismissPR(id: pr.id)
            }) {
                Label("Dismiss PR", systemImage: "xmark.circle")
            }
        }
    }

    private func loadReviewSummary() async {
        guard let owner = pr.base.repo?.fullName.components(separatedBy: "/").first,
              let repo = pr.base.repo?.name else { return }

        reviewSummary = await gitHubService.fetchPRReviewSummary(owner: owner, repo: repo, number: pr.number)
    }
}

// MARK: - Relative Time Formatter

extension Date {
    func relativeTimeString() -> String {
        let now = Date()
        let interval = now.timeIntervalSince(self)

        if interval < 0 {
            return "just now"
        }

        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)
        let weeks = Int(interval / 604800)
        let months = Int(interval / 2592000)

        if minutes < 1 {
            return "just now"
        } else if minutes < 60 {
            return "\(minutes)m ago"
        } else if hours < 24 {
            return "\(hours)h ago"
        } else if days < 7 {
            return "\(days)d ago"
        } else if weeks < 4 {
            return "\(weeks)w ago"
        } else {
            return "\(months)mo ago"
        }
    }
}

#Preview {
    ContentView()
}

