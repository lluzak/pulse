//
//  GitHubService.swift
//  pulse
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import Foundation
import AppKit
import UserNotifications

enum NotificationAuthorizationStatus {
    case authorized, denied, notDetermined, provisional, ephemeral
}

@Observable
class GitHubService {
    static let shared = GitHubService()

    var isAuthenticated: Bool = false
    var isCheckingAuth: Bool = true  // True until initial token validation completes
    var personalAccessToken: String? {
        didSet {
            if personalAccessToken != nil {
                saveToken()
            }
        }
    }
    var currentUser: GitHubUser?
    var awaitingReviewPRs: [PullRequest] = []
    var involvedPRs: [PullRequest] = []
    var isLoadingAwaiting: Bool = false
    var isLoadingInvolved: Bool = false
    var hasLoadedAwaiting: Bool = false
    var hasLoadedInvolved: Bool = false
    var errorMessage: String?

    var isLoading: Bool { isLoadingAwaiting || isLoadingInvolved }
    var hasLoadedOnce: Bool { hasLoadedAwaiting || hasLoadedInvolved }
    
    // Repository filtering
    var monitoredRepositories: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(monitoredRepositories), forKey: "monitoredRepositories") }
    }
    var monitorAllRepositories: Bool = true {
        didSet { UserDefaults.standard.set(monitorAllRepositories, forKey: "monitorAllRepositories") }
    }
    var availableRepositories: [GitHubRepository] = []
    var isLoadingRepositories: Bool = false

    // Review reminders
    var watchedPRs: [WatchedPR] = [] {
        didSet { saveWatchedPRs() }
    }
    var isReminderEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isReminderEnabled, forKey: "isReminderEnabled")
            if isReminderEnabled && !watchedPRs.isEmpty {
                startReminderPolling()
            } else {
                stopReminderPolling()
            }
        }
    }
    var reminderInterval: TimeInterval = 600 { // 10 minutes
        didSet {
            UserDefaults.standard.set(reminderInterval, forKey: "reminderInterval")
            // Restart polling with new interval if active
            if isReminderEnabled && !watchedPRs.isEmpty {
                startReminderPolling()
            }
        }
    }

    // Polling
    var isPollingEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isPollingEnabled, forKey: "isPollingEnabled")
            if isPollingEnabled {
                startPolling()
            } else {
                pollingTask?.cancel()
            }
        }
    }
    var pollingInterval: TimeInterval = 300 { // 5 minutes
        didSet { UserDefaults.standard.set(pollingInterval, forKey: "pollingInterval") }
    }
    private var pollingTask: Task<Void, Never>?
    private var reminderPollingTask: Task<Void, Never>?

    // Notification tracking
    private var previousPRIds: Set<Int> = []
    
    var notificationStatus: NotificationAuthorizationStatus = .notDetermined
    
    private let tokenKey = "github_token"
    
    init() {
        // Load saved settings
        loadSettings()

        requestNotificationPermission()
        checkNotificationPermissionStatus()
        loadToken()
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "pollingInterval") != nil {
            pollingInterval = defaults.double(forKey: "pollingInterval")
        }
        if defaults.object(forKey: "isPollingEnabled") != nil {
            isPollingEnabled = defaults.bool(forKey: "isPollingEnabled")
        }
        if defaults.object(forKey: "monitorAllRepositories") != nil {
            monitorAllRepositories = defaults.bool(forKey: "monitorAllRepositories")
        }
        if let repos = defaults.stringArray(forKey: "monitoredRepositories") {
            monitoredRepositories = Set(repos)
        }
        if defaults.object(forKey: "isReminderEnabled") != nil {
            isReminderEnabled = defaults.bool(forKey: "isReminderEnabled")
        }
        if defaults.object(forKey: "reminderInterval") != nil {
            reminderInterval = defaults.double(forKey: "reminderInterval")
        }
        loadWatchedPRs()
    }

    func resetLoadedState() {
        hasLoadedAwaiting = false
        hasLoadedInvolved = false
    }
    
    deinit {
        pollingTask?.cancel()
        reminderPollingTask?.cancel()
    }
    
    // MARK: - Notifications
    
    func sendNotification(for newPRs: [PullRequest]) {
        guard !newPRs.isEmpty else { return }

        // Show full-screen notification
        DispatchQueue.main.async {
            PRNotificationWindowController.shared.show(for: newPRs)
        }

        // Also send system notification
        let center = UNUserNotificationCenter.current()

        for pr in newPRs {
            let content = UNMutableNotificationContent()
            content.title = "New PR Review Request"
            content.subtitle = pr.repository
            content.body = pr.title
            content.sound = .default
            content.userInfo = ["prURL": pr.htmlURL]

            let request = UNNotificationRequest(
                identifier: "pr-\(pr.id)",
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error = error {
                    print("[Pulse] Notification error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error = error {
                print("[Pulse] Notification permission error: \(error.localizedDescription)")
            }
        }
    }
    
    func checkNotificationPermissionStatus() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized:
                    self.notificationStatus = .authorized
                case .denied:
                    self.notificationStatus = .denied
                case .notDetermined:
                    self.notificationStatus = .notDetermined
                case .provisional:
                    self.notificationStatus = .provisional
                case .ephemeral:
                    self.notificationStatus = .ephemeral
                @unknown default:
                    self.notificationStatus = .notDetermined
                }
            }
        }
    }
    
    // MARK: - Authentication
    
    func authenticate(token: String) async {
        self.personalAccessToken = token
        await fetchCurrentUser()
        // Start polling after successful authentication
        startPolling()
    }
    
    func signOut() {
        isAuthenticated = false
        personalAccessToken = nil
        currentUser = nil
        awaitingReviewPRs = []
        involvedPRs = []
        hasLoadedAwaiting = false
        hasLoadedInvolved = false
        previousPRIds = []
        pollingTask?.cancel()
        KeychainHelper.delete(key: tokenKey)
    }
    
    private func saveToken() {
        guard let token = personalAccessToken else { return }
        KeychainHelper.save(key: tokenKey, value: token)
    }
    
    private func loadToken() {
        if let token = KeychainHelper.load(key: tokenKey) {
            personalAccessToken = token
            // isAuthenticated will be set after fetchCurrentUser succeeds
            Task {
                await fetchCurrentUser()
                isCheckingAuth = false
                // Start polling after loading token and fetching user
                startPolling()
            }
        } else {
            // No stored token, done checking
            isCheckingAuth = false
        }
    }
    
    // MARK: - Polling
    
    /// Starts polling for new PRs at the configured interval.
    private func startPolling() {
        pollingTask?.cancel()
        guard isPollingEnabled else { return }

        pollingTask = Task {
            while !Task.isCancelled {
                await fetchAllPRs()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }
        }
    }
    
    // MARK: - API Calls
    
    func fetchCurrentUser() async {
        guard let token = personalAccessToken else { return }

        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            currentUser = try JSONDecoder().decode(GitHubUser.self, from: data)
            isAuthenticated = true
            await fetchAllPRs()
        } catch {
            errorMessage = "Failed to authenticate: \(error.localizedDescription)"
            isAuthenticated = false
            personalAccessToken = nil
            KeychainHelper.delete(key: tokenKey)
        }
    }
    
    func fetchPendingPRs() async {
        guard personalAccessToken != nil, let username = currentUser?.login else { return }

        isLoadingAwaiting = true
        errorMessage = nil

        var allPRs: [PullRequest] = []

        if monitorAllRepositories {
            let query = "type:pr state:open review-requested:\(username)"
            allPRs = await searchPRs(query: query, username: username)
        } else if !monitoredRepositories.isEmpty {
            for repo in monitoredRepositories {
                let query = "type:pr state:open repo:\(repo) review-requested:\(username)"
                let prs = await searchPRs(query: query, username: username)
                allPRs.append(contentsOf: prs)
            }
        } else {
            isLoadingAwaiting = false
            return
        }

        let sortedPRs = allPRs.sorted { $0.updatedDate > $1.updatedDate }

        // Determine new PRs by comparing IDs with previousPRIds
        let currentPRIds = Set(sortedPRs.map { $0.id })
        let newPRs = sortedPRs.filter { !previousPRIds.contains($0.id) }

        // Send notifications for new PRs (only after first load)
        if hasLoadedAwaiting && !newPRs.isEmpty {
            sendNotification(for: newPRs)
        }

        previousPRIds = currentPRIds
        awaitingReviewPRs = sortedPRs
        hasLoadedAwaiting = true
        isLoadingAwaiting = false
    }

    func fetchAllPRs() async {
        // Fetch both in parallel
        async let awaitingTask: () = fetchPendingPRs()
        async let involvedTask: () = fetchInvolvedPRs()
        _ = await (awaitingTask, involvedTask)
    }
    
    func fetchInvolvedPRs() async {
        guard personalAccessToken != nil, let username = currentUser?.login else { return }

        isLoadingInvolved = true

        var allPRs: [PullRequest] = []

        if monitorAllRepositories {
            let query = "type:pr state:open involves:\(username)"
            allPRs = await searchPRs(query: query, username: username)
        } else if !monitoredRepositories.isEmpty {
            for repo in monitoredRepositories {
                let query = "type:pr state:open repo:\(repo) involves:\(username)"
                let prs = await searchPRs(query: query, username: username)
                allPRs.append(contentsOf: prs)
            }
        } else {
            isLoadingInvolved = false
            return
        }

        let sortedPRs = allPRs.sorted { $0.updatedDate > $1.updatedDate }

        involvedPRs = sortedPRs
        hasLoadedInvolved = true
        isLoadingInvolved = false
    }

    func fetchRepositories() async {
        guard let token = personalAccessToken else { return }

        isLoadingRepositories = true

        var allRepos: [GitHubRepository] = []
        var page = 1
        let perPage = 100

        // Fetch all repositories the user has access to
        while true {
            let urlString = "https://api.github.com/user/repos?per_page=\(perPage)&page=\(page)&sort=pushed"
            guard let url = URL(string: urlString) else { break }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let repos = try JSONDecoder().decode([GitHubRepository].self, from: data)

                if repos.isEmpty {
                    break
                }

                allRepos.append(contentsOf: repos)
                page += 1

                // Safety limit
                if page > 10 { break }
            } catch {
                break
            }
        }

        availableRepositories = allRepos.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
        isLoadingRepositories = false
    }

    func toggleRepository(_ repo: String) {
        if monitoredRepositories.contains(repo) {
            monitoredRepositories.remove(repo)
        } else {
            monitoredRepositories.insert(repo)
        }
    }

    private func saveWatchedPRs() {
        if let data = try? JSONEncoder().encode(watchedPRs) {
            UserDefaults.standard.set(data, forKey: "watchedPRs")
        }
    }

    private func loadWatchedPRs() {
        if let data = UserDefaults.standard.data(forKey: "watchedPRs"),
           let prs = try? JSONDecoder().decode([WatchedPR].self, from: data) {
            // Set directly to avoid triggering save
            watchedPRs = prs

            // Start polling if there are watched PRs
            if !prs.isEmpty && isReminderEnabled {
                startReminderPolling()
            }
        }
    }

    func startWatching(pr: PullRequest) {
        // Don't add duplicates
        guard !isWatching(prId: pr.id) else { return }

        let watched = WatchedPR(
            id: pr.id,
            prNumber: pr.number,
            owner: pr.base.repo.fullName.components(separatedBy: "/").first ?? "",
            repo: pr.base.repo.name,
            repository: pr.repository,
            title: pr.title,
            htmlURL: pr.htmlURL,
            authorLogin: pr.user.login,
            authorAvatarURL: pr.user.avatarURL,
            startedWatchingAt: Date(),
            lastReminderAt: nil
        )
        watchedPRs.append(watched)

        // Start polling if this is the first watched PR
        if watchedPRs.count == 1 {
            startReminderPolling()
        }
    }

    func stopWatching(prId: Int) {
        watchedPRs.removeAll { $0.id == prId }
    }

    func isWatching(prId: Int) -> Bool {
        watchedPRs.contains { $0.id == prId }
    }

    func clearAllWatchedPRs() {
        watchedPRs.removeAll()
    }

    private func searchPRs(query: String, username: String) async -> [PullRequest] {
        guard let token = personalAccessToken else { return [] }
        
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.github.com/search/issues?q=\(encodedQuery)&sort=updated&order=desc&per_page=100"

        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let searchResponse = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)

            // Fetch full details for each PR
            var detailedPRs: [PullRequest] = []
            for item in searchResponse.items {
                if let prDetails = await fetchPRDetails(owner: item.repositoryOwner, repo: item.repositoryName, number: item.number) {
                    // Skip PRs authored by the user
                    if prDetails.user.login != username {
                        detailedPRs.append(prDetails)
                    }
                }
            }

            return detailedPRs

        } catch {
            print("[Pulse] Search error: \(error.localizedDescription)")
            return []
        }
    }
    
    private func fetchPRDetails(owner: String, repo: String, number: Int) async -> PullRequest? {
        guard let token = personalAccessToken else { return nil }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return nil
            }

            return try JSONDecoder().decode(PullRequest.self, from: data)
        } catch {
            return nil
        }
    }

    func getUserReviewStatus(owner: String, repo: String, number: Int) async -> UserReviewStatus {
        guard let token = personalAccessToken, let username = currentUser?.login else {
            return UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)
        }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/reviews")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)
            }

            let reviews = try JSONDecoder().decode([PRReviewResponse].self, from: data)

            // Find user's most recent submitted review (not PENDING)
            let validStates = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]
            let userReviews = reviews
                .filter { $0.user.login == username && validStates.contains($0.state) }
                .sorted { ($0.submittedAt ?? "") > ($1.submittedAt ?? "") }

            if let latestReview = userReviews.first {
                let submittedAt = latestReview.submittedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                return UserReviewStatus(
                    hasReviewed: true,
                    state: latestReview.state,
                    submittedAt: submittedAt
                )
            }

            return UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)
        } catch {
            print("[Pulse] Error checking review status: \(error.localizedDescription)")
            return UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)
        }
    }

    func checkWatchedPRStatus(pr: WatchedPR) async -> (status: WatchedPRStatus, reviewState: String?, reviewedAt: Date?) {
        // First check if PR is still open
        guard let prDetails = await fetchPRDetails(owner: pr.owner, repo: pr.repo, number: pr.prNumber) else {
            // Can't fetch PR, assume closed/deleted
            return (.closed, nil, nil)
        }

        if prDetails.state != "open" {
            return (.closed, nil, nil)
        }

        // Get user's review status
        let reviewStatus = await getUserReviewStatus(owner: pr.owner, repo: pr.repo, number: pr.prNumber)

        // If user approved → done, remove from list
        if reviewStatus.state == "APPROVED" {
            return (.approved, reviewStatus.state, reviewStatus.submittedAt)
        }

        // If user submitted CHANGES_REQUESTED or COMMENTED
        if reviewStatus.hasReviewed, let reviewedAt = reviewStatus.submittedAt {
            // Check if author responded (PR updated after review)
            if prDetails.updatedDate > reviewedAt {
                // Author responded, remind again
                return (.needsReminder, reviewStatus.state, reviewStatus.submittedAt)
            } else {
                // Still waiting for author
                return (.waitingForAuthor, reviewStatus.state, reviewStatus.submittedAt)
            }
        }

        // No review yet → remind
        return (.needsReminder, nil, nil)
    }

    func startReminderPolling() {
        reminderPollingTask?.cancel()
        guard isReminderEnabled && !watchedPRs.isEmpty else { return }

        reminderPollingTask = Task {
            while !Task.isCancelled {
                // Sleep first, then check - prevents immediate reminder after adding PR
                try? await Task.sleep(nanoseconds: UInt64(reminderInterval * 1_000_000_000))
                await checkWatchedPRs()
            }
        }
    }

    func stopReminderPolling() {
        reminderPollingTask?.cancel()
        reminderPollingTask = nil
    }

    func checkWatchedPRs() async {
        guard !watchedPRs.isEmpty else {
            stopReminderPolling()
            return
        }

        var prsNeedingReminder: [WatchedPR] = []
        var prsToRemove: [Int] = []
        var prsToUpdate: [(id: Int, reviewState: String?, reviewedAt: Date?)] = []

        for pr in watchedPRs {
            // Skip if not enough time passed since watching started (initial delay)
            let timeSinceStart = Date().timeIntervalSince(pr.startedWatchingAt)
            if timeSinceStart < reminderInterval {
                continue
            }

            let (status, reviewState, reviewedAt) = await checkWatchedPRStatus(pr: pr)

            switch status {
            case .approved, .closed:
                prsToRemove.append(pr.id)
            case .waitingForAuthor:
                // Update review state but don't remind (waiting for author)
                if reviewState != pr.lastReviewState || reviewedAt != pr.lastReviewedAt {
                    prsToUpdate.append((pr.id, reviewState, reviewedAt))
                }
            case .needsReminder:
                // Update review state if changed
                if reviewState != pr.lastReviewState || reviewedAt != pr.lastReviewedAt {
                    prsToUpdate.append((pr.id, reviewState, reviewedAt))
                }
                prsNeedingReminder.append(pr)
            }
        }

        // Update review states
        for update in prsToUpdate {
            if let index = watchedPRs.firstIndex(where: { $0.id == update.id }) {
                watchedPRs[index].lastReviewState = update.reviewState
                watchedPRs[index].lastReviewedAt = update.reviewedAt
            }
        }

        // Remove completed/closed PRs
        for prId in prsToRemove {
            stopWatching(prId: prId)
        }

        // Send reminders
        if !prsNeedingReminder.isEmpty {
            await MainActor.run {
                sendReminderNotification(for: prsNeedingReminder)
            }
        }

        // Stop polling if no more watched PRs
        if watchedPRs.isEmpty {
            stopReminderPolling()
        }
    }

    func sendReminderNotification(for watchedPRs: [WatchedPR]) {
        DispatchQueue.main.async {
            PRNotificationWindowController.shared.showReminder(for: watchedPRs)
        }
    }

    func openPRInBrowser(_ pr: PullRequest) {
        if let url = URL(string: pr.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Models

struct GitHubUser: Codable {
    let login: String
    let id: Int
    let avatarURL: String
    let name: String?
    
    enum CodingKeys: String, CodingKey {
        case login, id, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubOrganization: Codable {
    let login: String
    let id: Int
    let avatarURL: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case login, id, description
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepository: Codable, Identifiable {
    let id: Int
    let name: String
    let fullName: String
    let isPrivate: Bool
    let owner: GitHubRepoOwner

    enum CodingKeys: String, CodingKey {
        case id, name, owner
        case fullName = "full_name"
        case isPrivate = "private"
    }
}

struct GitHubRepoOwner: Codable {
    let login: String
    let avatarURL: String

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct GitHubSearchResponse: Codable {
    let totalCount: Int
    let items: [GitHubIssue]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
    }
}

struct GitHubIssue: Codable {
    let number: Int
    let title: String
    let repositoryURL: String
    
    var repositoryOwner: String {
        let components = repositoryURL.split(separator: "/")
        return components.count >= 2 ? String(components[components.count - 2]) : ""
    }
    
    var repositoryName: String {
        let components = repositoryURL.split(separator: "/")
        return components.count >= 1 ? String(components[components.count - 1]) : ""
    }
    
    enum CodingKeys: String, CodingKey {
        case number, title
        case repositoryURL = "repository_url"
    }
}

struct PullRequest: Codable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let htmlURL: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let user: PRUser
    let draft: Bool
    let head: PRBranch
    let base: PRBranch
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    
    var repository: String {
        base.repo.fullName
    }
    
    var createdDate: Date {
        ISO8601DateFormatter().date(from: createdAt) ?? Date()
    }
    
    var updatedDate: Date {
        ISO8601DateFormatter().date(from: updatedAt) ?? Date()
    }
    
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, user, draft, head, base, additions, deletions
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case changedFiles = "changed_files"
    }
}

struct PRUser: Codable {
    let login: String
    let avatarURL: String
    
    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct PRBranch: Codable {
    let ref: String
    let repo: PRRepository
}

struct PRRepository: Codable {
    let name: String
    let fullName: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
    }
}

struct PRReview: Codable {
    let id: Int
    let user: PRUser
    let state: String
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, state
        case submittedAt = "submitted_at"
    }
}

struct PRReviewResponse: Codable {
    let id: Int
    let user: PRUser
    let state: String
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, user, state
        case submittedAt = "submitted_at"
    }
}

// MARK: - Watched PR Model

struct WatchedPR: Codable, Identifiable {
    let id: Int
    let prNumber: Int
    let owner: String
    let repo: String
    let repository: String
    let title: String
    let htmlURL: String
    let authorLogin: String
    let authorAvatarURL: String
    let startedWatchingAt: Date
    var lastReminderAt: Date?
    var lastReviewedAt: Date?       // When user last submitted review
    var lastReviewState: String?    // APPROVED, CHANGES_REQUESTED, COMMENTED
}

enum WatchedPRStatus {
    case needsReminder      // No review yet, or author responded after review
    case waitingForAuthor   // User reviewed, waiting for author response
    case approved           // User approved, can remove
    case closed             // PR closed/merged
}

// Review status returned from GitHub API check
struct UserReviewStatus {
    let hasReviewed: Bool
    let state: String?      // APPROVED, CHANGES_REQUESTED, COMMENTED
    let submittedAt: Date?
}

// MARK: - Keychain Helper

class KeychainHelper {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

