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

    // My PRs tab
    var myPRs: [PullRequest] = []
    var isLoadingMyPRs: Bool = false
    var hasLoadedMyPRs: Bool = false
    var myPRsStateFilter: PRStateFilter = .open

    // Activity tracking for My PRs notifications
    var myPRsLastActivity: [Int: PRActivity] = [:] {
        didSet { saveMyPRsActivity() }
    }

    // My PRs notification settings
    var myPRNotificationSettings: MyPRNotificationSettings = MyPRNotificationSettings() {
        didSet { saveMyPRNotificationSettings() }
    }

    var errorMessage: String?

    var isLoading: Bool { isLoadingAwaiting || isLoadingInvolved || isLoadingMyPRs }
    var hasLoadedOnce: Bool { hasLoadedAwaiting || hasLoadedInvolved || hasLoadedMyPRs }
    
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

    // Dismissed PRs (won't show in list)
    var dismissedPRIds: Set<Int> = [] {
        didSet {
            // Persist to UserDefaults
            UserDefaults.standard.set(Array(dismissedPRIds), forKey: "dismissedPRIds")
        }
    }
    
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
        if let dismissed = defaults.array(forKey: "dismissedPRIds") as? [Int] {
            dismissedPRIds = Set(dismissed)
        }
        loadWatchedPRs()
        loadMyPRsActivity()
        loadMyPRNotificationSettings()
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

    /// Send a test notification (system notification only, no full-screen or watching)
    func sendTestNotification() {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.subtitle = "octocat/Hello-World"
        content.body = "This is a test notification from Pulse"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "test-notification-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error = error {
                print("[Pulse] Test notification error: \(error.localizedDescription)")
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
        myPRs = []
        hasLoadedAwaiting = false
        hasLoadedInvolved = false
        hasLoadedMyPRs = false
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
        // Filter out dismissed PRs
        awaitingReviewPRs = sortedPRs.filter { !dismissedPRIds.contains($0.id) }
        hasLoadedAwaiting = true
        isLoadingAwaiting = false
    }

    func fetchAllPRs() async {
        // Fetch all three in parallel
        async let awaitingTask: () = fetchPendingPRs()
        async let involvedTask: () = fetchInvolvedPRs()
        async let myPRsTask: () = fetchMyPRs()
        _ = await (awaitingTask, involvedTask, myPRsTask)
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

        // Filter out dismissed PRs
        involvedPRs = sortedPRs.filter { !dismissedPRIds.contains($0.id) }
        hasLoadedInvolved = true
        isLoadingInvolved = false
    }

    func fetchMyPRs() async {
        guard personalAccessToken != nil, let username = currentUser?.login else { return }

        isLoadingMyPRs = true

        var allPRs: [PullRequest] = []

        // Build query based on filter
        var queryParts = ["type:pr", "author:\(username)"]

        switch myPRsStateFilter {
        case .open:
            queryParts.append("state:open")
        case .closed:
            queryParts.append("state:closed")
            queryParts.append("is:unmerged")
        case .merged:
            queryParts.append("is:merged")
        case .all:
            break  // No state filter
        }

        if monitorAllRepositories {
            let query = queryParts.joined(separator: " ")
            allPRs = await searchMyPRs(query: query)
        } else if !monitoredRepositories.isEmpty {
            for repo in monitoredRepositories {
                var repoQuery = queryParts
                repoQuery.append("repo:\(repo)")
                let query = repoQuery.joined(separator: " ")
                let prs = await searchMyPRs(query: query)
                allPRs.append(contentsOf: prs)
            }
        } else {
            isLoadingMyPRs = false
            return
        }

        let sortedPRs = allPRs.sorted { $0.updatedDate > $1.updatedDate }

        // Check for activity changes and send notifications (only after first load)
        if hasLoadedMyPRs {
            await checkMyPRsForActivityChanges(sortedPRs)
        }

        // Filter out dismissed PRs
        myPRs = sortedPRs.filter { !dismissedPRIds.contains($0.id) }
        hasLoadedMyPRs = true
        isLoadingMyPRs = false
    }

    private func searchMyPRs(query: String) async -> [PullRequest] {
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

            // Fetch full details for each PR (we need review info)
            var detailedPRs: [PullRequest] = []
            for item in searchResponse.items {
                if let prDetails = await fetchPRDetails(owner: item.repositoryOwner, repo: item.repositoryName, number: item.number) {
                    detailedPRs.append(prDetails)
                }
            }

            return detailedPRs
        } catch {
            print("[Pulse] My PRs search error: \(error.localizedDescription)")
            return []
        }
    }

    private func checkMyPRsForActivityChanges(_ currentPRs: [PullRequest]) async {
        var eventsToNotify: [(PullRequest, [MyPRNotificationEvent])] = []

        for pr in currentPRs {
            guard let owner = pr.base.repo?.fullName.components(separatedBy: "/").first,
                  let repo = pr.base.repo?.name else { continue }

            // Get current activity
            let currentActivity = await fetchPRActivity(owner: owner, repo: repo, number: pr.number, pr: pr)

            // Compare with stored activity
            if let previousActivity = myPRsLastActivity[pr.id] {
                let events = detectActivityChanges(previous: previousActivity, current: currentActivity, pr: pr)
                if !events.isEmpty {
                    eventsToNotify.append((pr, events))
                }
            }

            // Update stored activity
            myPRsLastActivity[pr.id] = currentActivity
        }

        // Send notifications based on settings
        if !eventsToNotify.isEmpty {
            await sendMyPRNotifications(events: eventsToNotify)
        }
    }

    private func fetchPRActivity(owner: String, repo: String, number: Int, pr: PullRequest) async -> PRActivity {
        // Get reviews
        let reviews = await fetchPRReviews(owner: owner, repo: repo, number: number)

        let approvalCount = reviews.filter { $0.state == "APPROVED" }.count
        let changesRequestedCount = reviews.filter { $0.state == "CHANGES_REQUESTED" }.count
        let reviewCount = reviews.filter { ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].contains($0.state) }.count
        let latestReview = reviews.sorted { ($0.submittedAt ?? "") > ($1.submittedAt ?? "") }.first

        // Get comment count (issue comments, not review comments)
        let commentCount = await fetchPRCommentCount(owner: owner, repo: repo, number: number)

        // Check merge status
        let isMerged = pr.state == "closed" && (pr.mergedAt != nil)
        let mergedAt = pr.mergedAt.flatMap { ISO8601DateFormatter().date(from: $0) }

        // For now, we don't have easy access to conflicts or check status from search results
        // These would require additional API calls - leave as placeholders
        let hasConflicts = false
        let checkStatus: String? = nil

        return PRActivity(
            commentCount: commentCount,
            reviewCount: reviewCount,
            approvalCount: approvalCount,
            changesRequestedCount: changesRequestedCount,
            latestReviewState: latestReview?.state,
            isMerged: isMerged,
            mergedAt: mergedAt,
            hasConflicts: hasConflicts,
            checkStatus: checkStatus
        )
    }

    private func fetchPRReviews(owner: String, repo: String, number: Int) async -> [PRReviewResponse] {
        guard let token = personalAccessToken else { return [] }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/reviews")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return []
            }
            return try JSONDecoder().decode([PRReviewResponse].self, from: data)
        } catch {
            return []
        }
    }

    private func fetchPRCommentCount(owner: String, repo: String, number: Int) async -> Int {
        guard let token = personalAccessToken else { return 0 }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/issues/\(number)/comments")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return 0
            }
            let comments = try JSONDecoder().decode([PRComment].self, from: data)
            return comments.count
        } catch {
            return 0
        }
    }

    func fetchPRReviewSummary(owner: String, repo: String, number: Int) async -> PRReviewSummary {
        let reviews = await fetchPRReviews(owner: owner, repo: repo, number: number)

        // Group by user and get their latest review
        var latestByUser: [String: PRReviewResponse] = [:]
        for review in reviews.sorted(by: { ($0.submittedAt ?? "") < ($1.submittedAt ?? "") }) {
            if ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].contains(review.state) {
                latestByUser[review.user.login] = review
            }
        }

        let approvedCount = latestByUser.values.filter { $0.state == "APPROVED" }.count
        let changesRequestedCount = latestByUser.values.filter { $0.state == "CHANGES_REQUESTED" }.count
        let commentedCount = latestByUser.values.filter { $0.state == "COMMENTED" }.count

        return PRReviewSummary(
            approvedCount: approvedCount,
            changesRequestedCount: changesRequestedCount,
            commentedCount: commentedCount,
            pendingCount: 0
        )
    }

    private func detectActivityChanges(previous: PRActivity, current: PRActivity, pr: PullRequest) -> [MyPRNotificationEvent] {
        var events: [MyPRNotificationEvent] = []

        // Check for new approval
        if current.approvalCount > previous.approvalCount {
            events.append(.approval(reviewer: "someone"))
        }

        // Check for changes requested
        if current.changesRequestedCount > previous.changesRequestedCount {
            events.append(.changesRequested(reviewer: "someone"))
        }

        // Check for new review comment
        if current.reviewCount > previous.reviewCount &&
           current.approvalCount == previous.approvalCount &&
           current.changesRequestedCount == previous.changesRequestedCount {
            events.append(.reviewComment(reviewer: "someone"))
        }

        // Check for new comment
        if current.commentCount > previous.commentCount {
            events.append(.comment(commenter: "someone"))
        }

        // Check for merge
        if current.isMerged && !previous.isMerged {
            events.append(.merged)
        }

        // Check for conflict (when we implement it)
        if current.hasConflicts && !previous.hasConflicts {
            events.append(.conflict)
        }

        // Check for CI status changes (when we implement it)
        if let currentCheck = current.checkStatus, let previousCheck = previous.checkStatus {
            if currentCheck == "failure" && previousCheck != "failure" {
                events.append(.checkFailure)
            } else if currentCheck == "success" && previousCheck != "success" {
                events.append(.checkSuccess)
            }
        }

        return events
    }

    private func sendMyPRNotifications(events: [(PullRequest, [MyPRNotificationEvent])]) async {
        let settings = myPRNotificationSettings

        for (pr, prEvents) in events {
            for event in prEvents {
                let shouldNotify: Bool
                let title: String
                let body: String

                switch event {
                case .approval(let reviewer):
                    shouldNotify = settings.notifyOnApproval
                    title = "PR Approved"
                    body = "\(reviewer) approved #\(pr.number): \(pr.title)"
                case .changesRequested(let reviewer):
                    shouldNotify = settings.notifyOnChangesRequested
                    title = "Changes Requested"
                    body = "\(reviewer) requested changes on #\(pr.number): \(pr.title)"
                case .reviewComment(let reviewer):
                    shouldNotify = settings.notifyOnReviewComment
                    title = "New Review Comment"
                    body = "\(reviewer) commented on #\(pr.number): \(pr.title)"
                case .comment(let commenter):
                    shouldNotify = settings.notifyOnComment
                    title = "New Comment"
                    body = "\(commenter) commented on #\(pr.number): \(pr.title)"
                case .checkFailure:
                    shouldNotify = settings.notifyOnCheckFailure
                    title = "CI Failed"
                    body = "Checks failed on #\(pr.number): \(pr.title)"
                case .checkSuccess:
                    shouldNotify = settings.notifyOnCheckSuccess
                    title = "CI Passed"
                    body = "Checks passed on #\(pr.number): \(pr.title)"
                case .mention:
                    shouldNotify = settings.notifyOnMention
                    title = "You were mentioned"
                    body = "You were mentioned in #\(pr.number): \(pr.title)"
                case .merged:
                    shouldNotify = settings.notifyOnMerge
                    title = "PR Merged"
                    body = "#\(pr.number) was merged: \(pr.title)"
                case .conflict:
                    shouldNotify = settings.notifyOnConflict
                    title = "Merge Conflict"
                    body = "#\(pr.number) has conflicts: \(pr.title)"
                }

                if shouldNotify {
                    await MainActor.run {
                        sendSystemNotification(title: title, body: body, prURL: pr.htmlURL)
                    }
                }
            }
        }
    }

    private func sendSystemNotification(title: String, body: String, prURL: String) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["prURL": prURL]

        let request = UNNotificationRequest(
            identifier: "mypr-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error = error {
                print("[Pulse] My PR notification error: \(error.localizedDescription)")
            }
        }
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

    private func saveMyPRsActivity() {
        if let data = try? JSONEncoder().encode(myPRsLastActivity) {
            UserDefaults.standard.set(data, forKey: "myPRsLastActivity")
        }
    }

    private func loadMyPRsActivity() {
        if let data = UserDefaults.standard.data(forKey: "myPRsLastActivity"),
           let activity = try? JSONDecoder().decode([Int: PRActivity].self, from: data) {
            myPRsLastActivity = activity
        }
    }

    private func saveMyPRNotificationSettings() {
        if let data = try? JSONEncoder().encode(myPRNotificationSettings) {
            UserDefaults.standard.set(data, forKey: "myPRNotificationSettings")
        }
    }

    private func loadMyPRNotificationSettings() {
        if let data = UserDefaults.standard.data(forKey: "myPRNotificationSettings"),
           let settings = try? JSONDecoder().decode(MyPRNotificationSettings.self, from: data) {
            myPRNotificationSettings = settings
        }
    }

    func startWatching(pr: PullRequest) {
        // Don't add duplicates
        guard !isWatching(prId: pr.id) else { return }

        let watched = WatchedPR(
            id: pr.id,
            prNumber: pr.number,
            owner: pr.base.repo?.fullName.components(separatedBy: "/").first ?? "",
            repo: pr.base.repo?.name ?? "",
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

    // MARK: - Dismiss PRs

    func dismissPR(id: Int) {
        dismissedPRIds.insert(id)
        // Also stop watching if we were
        stopWatching(prId: id)
        // Remove from current lists immediately
        awaitingReviewPRs.removeAll { $0.id == id }
        involvedPRs.removeAll { $0.id == id }
        myPRs.removeAll { $0.id == id }
    }

    func undismissPR(id: Int) {
        dismissedPRIds.remove(id)
    }

    func clearAllDismissedPRs() {
        dismissedPRIds.removeAll()
    }

    func isPRDismissed(id: Int) -> Bool {
        dismissedPRIds.contains(id)
    }

    func snoozePR(prId: Int, minutes: Int) {
        if let index = watchedPRs.firstIndex(where: { $0.id == prId }) {
            watchedPRs[index].snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    func snoozeNewPR(pr: PullRequest, minutes: Int) {
        // Start watching with a snooze
        guard !isWatching(prId: pr.id) else {
            // Already watching, just update snooze
            snoozePR(prId: pr.id, minutes: minutes)
            return
        }

        let watched = WatchedPR(
            id: pr.id,
            prNumber: pr.number,
            owner: pr.base.repo?.fullName.components(separatedBy: "/").first ?? "",
            repo: pr.base.repo?.name ?? "",
            repository: pr.repository,
            title: pr.title,
            htmlURL: pr.htmlURL,
            authorLogin: pr.user.login,
            authorAvatarURL: pr.user.avatarURL,
            startedWatchingAt: Date(),
            lastReminderAt: nil,
            snoozedUntil: Date().addingTimeInterval(TimeInterval(minutes * 60))
        )
        watchedPRs.append(watched)

        if watchedPRs.count == 1 {
            startReminderPolling()
        }
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

        } catch let decodingError as DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                print("[Pulse] Search decode error - missing key '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .valueNotFound(let type, let context):
                print("[Pulse] Search decode error - missing value of type '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .typeMismatch(let type, let context):
                print("[Pulse] Search decode error - type mismatch '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .dataCorrupted(let context):
                print("[Pulse] Search decode error - data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            @unknown default:
                print("[Pulse] Search decode error: \(decodingError.localizedDescription)")
            }
            return []
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
        } catch let decodingError as DecodingError {
            switch decodingError {
            case .keyNotFound(let key, let context):
                print("[Pulse] PR decode error (\(owner)/\(repo)#\(number)) - missing key '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .valueNotFound(let type, let context):
                print("[Pulse] PR decode error (\(owner)/\(repo)#\(number)) - missing value of type '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .typeMismatch(let type, let context):
                print("[Pulse] PR decode error (\(owner)/\(repo)#\(number)) - type mismatch '\(type)' at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .dataCorrupted(let context):
                print("[Pulse] PR decode error (\(owner)/\(repo)#\(number)) - data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            @unknown default:
                print("[Pulse] PR decode error (\(owner)/\(repo)#\(number)): \(decodingError.localizedDescription)")
            }
            return nil
        } catch {
            print("[Pulse] PR fetch error (\(owner)/\(repo)#\(number)): \(error.localizedDescription)")
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

            // Skip if snoozed
            if let snoozedUntil = pr.snoozedUntil, Date() < snoozedUntil {
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
                print("[Pulse] PR #\(pr.prNumber) still needs review, added to reminder list")
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
    let mergedAt: String?

    var repository: String {
        base.repo?.fullName ?? "unknown"
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
        case mergedAt = "merged_at"
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
    let repo: PRRepository?  // Can be null for deleted forks
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

struct PRComment: Codable {
    let id: Int
    let user: PRUser
    let body: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, user, body
        case createdAt = "created_at"
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
    var snoozedUntil: Date?         // If set, don't remind until this time
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

// MARK: - PR State Filter (for My PRs tab)

enum PRStateFilter: String, CaseIterable {
    case open = "Open"
    case closed = "Closed"
    case merged = "Merged"
    case all = "All"

    var queryValue: String? {
        switch self {
        case .open: return "open"
        case .closed: return "closed"
        case .merged: return nil  // Merged is a subset of closed, handled separately
        case .all: return nil
        }
    }
}

// MARK: - PR Activity Tracking (for My PRs notifications)

struct PRActivity: Codable, Equatable {
    let commentCount: Int
    let reviewCount: Int
    let approvalCount: Int
    let changesRequestedCount: Int
    let latestReviewState: String?  // APPROVED, CHANGES_REQUESTED, COMMENTED
    let isMerged: Bool
    let mergedAt: Date?
    let hasConflicts: Bool
    let checkStatus: String?  // success, failure, pending
}

// MARK: - PR Review Summary (for My PRs tab)

struct PRReviewSummary {
    let approvedCount: Int
    let changesRequestedCount: Int
    let commentedCount: Int
    let pendingCount: Int

    var displayText: String {
        if approvedCount > 0 && changesRequestedCount == 0 {
            return "\(approvedCount) approved"
        } else if changesRequestedCount > 0 {
            return "\(changesRequestedCount) changes"
        } else if commentedCount > 0 {
            return "\(commentedCount) comments"
        } else if pendingCount > 0 {
            return "\(pendingCount) pending"
        }
        return "No reviews"
    }
}

// MARK: - My PR Notification Event Types

struct MyPRNotificationSettings: Codable {
    var notifyOnApproval: Bool = true
    var notifyOnChangesRequested: Bool = true
    var notifyOnReviewComment: Bool = true
    var notifyOnComment: Bool = true
    var notifyOnCheckFailure: Bool = true
    var notifyOnCheckSuccess: Bool = true
    var notifyOnMention: Bool = true
    var notifyOnMerge: Bool = true
    var notifyOnConflict: Bool = true
    var batchNotifications: Bool = false  // false = immediate, true = batched
}

enum MyPRNotificationEvent {
    case approval(reviewer: String)
    case changesRequested(reviewer: String)
    case reviewComment(reviewer: String)
    case comment(commenter: String)
    case checkFailure
    case checkSuccess
    case mention
    case merged
    case conflict
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

