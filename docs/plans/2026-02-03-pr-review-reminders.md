# PR Review Reminders Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add persistent reminders for PRs the user opened but hasn't reviewed yet.

**Architecture:** Track watched PRs in UserDefaults, poll GitHub API for review status, show reminder notifications when no review found. Reuse existing full-screen notification UI with minor modifications.

**Tech Stack:** Swift 6, SwiftUI, GitHub REST API, UserDefaults, async/await

---

## Task 1: Add WatchedPR Model

**Files:**
- Modify: `pulse/GitHubService.swift` (after line 595, before KeychainHelper)

**Step 1: Write the failing test**

Add to `pulseTests/pulseTests.swift`:

```swift
// MARK: - Watched PR Tests

final class WatchedPRTests: XCTestCase {

    func testWatchedPREncoding() throws {
        let watchedPR = WatchedPR(
            id: 12345,
            prNumber: 42,
            owner: "octocat",
            repo: "Hello-World",
            repository: "octocat/Hello-World",
            title: "Add new feature",
            htmlURL: "https://github.com/octocat/Hello-World/pull/42",
            authorLogin: "contributor",
            authorAvatarURL: "https://github.com/images/avatar.jpg",
            startedWatchingAt: Date(timeIntervalSince1970: 1700000000),
            lastReminderAt: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(watchedPR)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WatchedPR.self, from: data)

        XCTAssertEqual(decoded.id, 12345)
        XCTAssertEqual(decoded.prNumber, 42)
        XCTAssertEqual(decoded.owner, "octocat")
        XCTAssertEqual(decoded.repo, "Hello-World")
        XCTAssertEqual(decoded.repository, "octocat/Hello-World")
        XCTAssertEqual(decoded.title, "Add new feature")
        XCTAssertEqual(decoded.authorLogin, "contributor")
        XCTAssertNil(decoded.lastReminderAt)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: FAIL with "Cannot find 'WatchedPR' in scope"

**Step 3: Write minimal implementation**

Add to `pulse/GitHubService.swift` after `PRReview` struct (around line 595):

```swift
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
}

enum WatchedPRStatus {
    case needsReminder
    case reviewed
    case closed
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add WatchedPR model and WatchedPRStatus enum"
```

---

## Task 2: Add Watched PRs Storage and Settings

**Files:**
- Modify: `pulse/GitHubService.swift`

**Step 1: Write the failing test**

Add to `WatchedPRTests` class in `pulseTests/pulseTests.swift`:

```swift
    func testWatchedPRsStorageDefaults() {
        // Clear UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")
        defaults.removeObject(forKey: "isReminderEnabled")
        defaults.removeObject(forKey: "reminderInterval")

        let service = GitHubService()

        XCTAssertTrue(service.watchedPRs.isEmpty)
        XCTAssertTrue(service.isReminderEnabled)
        XCTAssertEqual(service.reminderInterval, 600) // 10 minutes
    }
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests/testWatchedPRsStorageDefaults test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: FAIL with "has no member 'watchedPRs'"

**Step 3: Write minimal implementation**

Add properties to `GitHubService` class (after `availableRepositories` around line 48):

```swift
    // Review reminders
    var watchedPRs: [WatchedPR] = [] {
        didSet { saveWatchedPRs() }
    }
    var isReminderEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isReminderEnabled, forKey: "isReminderEnabled") }
    }
    var reminderInterval: TimeInterval = 600 { // 10 minutes
        didSet { UserDefaults.standard.set(reminderInterval, forKey: "reminderInterval") }
    }
```

Add to `loadSettings()` method (around line 97):

```swift
        if defaults.object(forKey: "isReminderEnabled") != nil {
            isReminderEnabled = defaults.bool(forKey: "isReminderEnabled")
        }
        if defaults.object(forKey: "reminderInterval") != nil {
            reminderInterval = defaults.double(forKey: "reminderInterval")
        }
        loadWatchedPRs()
```

Add helper methods after `toggleRepository` (around line 377):

```swift
    private func saveWatchedPRs() {
        if let data = try? JSONEncoder().encode(watchedPRs) {
            UserDefaults.standard.set(data, forKey: "watchedPRs")
        }
    }

    private func loadWatchedPRs() {
        if let data = UserDefaults.standard.data(forKey: "watchedPRs"),
           let prs = try? JSONDecoder().decode([WatchedPR].self, from: data) {
            watchedPRs = prs
        }
    }
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests/testWatchedPRsStorageDefaults test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add watchedPRs storage and reminder settings"
```

---

## Task 3: Add Watch List Management Methods

**Files:**
- Modify: `pulse/GitHubService.swift`
- Modify: `pulseTests/pulseTests.swift`

**Step 1: Write the failing tests**

Add to `WatchedPRTests` class:

```swift
    func testStartWatching() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        let pr = createMockPR(id: 100, number: 42)

        service.startWatching(pr: pr)

        XCTAssertEqual(service.watchedPRs.count, 1)
        XCTAssertEqual(service.watchedPRs.first?.id, 100)
        XCTAssertEqual(service.watchedPRs.first?.prNumber, 42)
    }

    func testStopWatching() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        let pr = createMockPR(id: 100)

        service.startWatching(pr: pr)
        XCTAssertEqual(service.watchedPRs.count, 1)

        service.stopWatching(prId: 100)
        XCTAssertTrue(service.watchedPRs.isEmpty)
    }

    func testIsWatching() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        let pr = createMockPR(id: 100)

        XCTAssertFalse(service.isWatching(prId: 100))

        service.startWatching(pr: pr)
        XCTAssertTrue(service.isWatching(prId: 100))
    }

    func testClearAllWatchedPRs() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        service.startWatching(pr: createMockPR(id: 1))
        service.startWatching(pr: createMockPR(id: 2))
        XCTAssertEqual(service.watchedPRs.count, 2)

        service.clearAllWatchedPRs()
        XCTAssertTrue(service.watchedPRs.isEmpty)
    }

    func testStartWatchingDoesNotDuplicate() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        let pr = createMockPR(id: 100)

        service.startWatching(pr: pr)
        service.startWatching(pr: pr)

        XCTAssertEqual(service.watchedPRs.count, 1)
    }
```

**Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: FAIL with "has no member 'startWatching'"

**Step 3: Write minimal implementation**

Add methods to `GitHubService` after `loadWatchedPRs()`:

```swift
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
```

**Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: All PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add watch list management methods"
```

---

## Task 4: Add GitHub API Method for Review Checking

**Files:**
- Modify: `pulse/GitHubService.swift`

**Step 1: Write the failing test**

Add to `WatchedPRTests`:

```swift
    func testPRReviewResponseDecoding() throws {
        let json = """
        [
            {
                "id": 80,
                "user": {
                    "login": "octocat",
                    "avatar_url": "https://github.com/images/avatar.jpg"
                },
                "state": "APPROVED",
                "submitted_at": "2024-01-29T12:00:00Z"
            }
        ]
        """

        let data = json.data(using: .utf8)!
        let reviews = try JSONDecoder().decode([PRReviewResponse].self, from: data)

        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0].user.login, "octocat")
        XCTAssertEqual(reviews[0].state, "APPROVED")
    }
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests/testPRReviewResponseDecoding test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: FAIL with "Cannot find 'PRReviewResponse' in scope"

**Step 3: Write minimal implementation**

Add struct after `PRReview` in `GitHubService.swift`:

```swift
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
```

Add API method to `GitHubService` after `fetchPRDetails`:

```swift
    func hasUserReviewedPR(owner: String, repo: String, number: Int) async -> Bool {
        guard let token = personalAccessToken, let username = currentUser?.login else { return false }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(number)/reviews")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return false
            }

            let reviews = try JSONDecoder().decode([PRReviewResponse].self, from: data)

            // Check if user has submitted a review (not PENDING)
            let validStates = ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]
            return reviews.contains { review in
                review.user.login == username && validStates.contains(review.state)
            }
        } catch {
            print("[Pulse] Error checking review status: \(error.localizedDescription)")
            return false
        }
    }

    func checkWatchedPRStatus(pr: WatchedPR) async -> WatchedPRStatus {
        // First check if PR is still open
        if let prDetails = await fetchPRDetails(owner: pr.owner, repo: pr.repo, number: pr.prNumber) {
            if prDetails.state != "open" {
                return .closed
            }
        } else {
            // Can't fetch PR, assume closed/deleted
            return .closed
        }

        // Check if user has reviewed
        let hasReviewed = await hasUserReviewedPR(owner: pr.owner, repo: pr.repo, number: pr.prNumber)
        return hasReviewed ? .reviewed : .needsReminder
    }
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WatchedPRTests/testPRReviewResponseDecoding test 2>&1 | grep -E "(error:|passed|failed)"`

Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add GitHub API methods for review status checking"
```

---

## Task 5: Implement Reminder Polling

**Files:**
- Modify: `pulse/GitHubService.swift`

**Step 1: Add reminder polling task property**

Add after `pollingTask` property (around line 65):

```swift
    private var reminderPollingTask: Task<Void, Never>?
```

**Step 2: Add polling methods**

Add after `checkWatchedPRStatus`:

```swift
    func startReminderPolling() {
        reminderPollingTask?.cancel()
        guard isReminderEnabled && !watchedPRs.isEmpty else { return }

        reminderPollingTask = Task {
            while !Task.isCancelled {
                await checkWatchedPRs()
                try? await Task.sleep(nanoseconds: UInt64(reminderInterval * 1_000_000_000))
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

        for pr in watchedPRs {
            let status = await checkWatchedPRStatus(pr: pr)

            switch status {
            case .reviewed, .closed:
                prsToRemove.append(pr.id)
            case .needsReminder:
                prsNeedingReminder.append(pr)
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
```

**Step 3: Update startWatching to start polling**

Modify `startWatching` method to start polling when first PR is added:

```swift
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
```

**Step 4: Update deinit to cancel reminder polling**

Modify `deinit`:

```swift
    deinit {
        pollingTask?.cancel()
        reminderPollingTask?.cancel()
    }
```

**Step 5: Build to verify no compile errors**

Run: `xcodebuild -scheme pulse -configuration Debug build 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED (will have warning about `showReminder` not existing yet)

**Step 6: Commit**

```bash
git add pulse/GitHubService.swift
git commit -m "feat: implement reminder polling logic"
```

---

## Task 6: Update Notification UI for Reminders

**Files:**
- Modify: `pulse/pulseApp.swift`

**Step 1: Add showReminder method to PRNotificationWindowController**

Add method after `dismiss()` in `PRNotificationWindowController`:

```swift
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
```

**Step 2: Update FullScreenPRNotificationView signature**

Replace the entire `FullScreenPRNotificationView` struct with:

```swift
struct FullScreenPRNotificationView: View {
    let prs: [PullRequest]
    let watchedPRs: [WatchedPR]
    let isReminder: Bool
    let onOpen: (PullRequest) -> Void
    let onOpenWatched: (WatchedPR) -> Void
    let onDismiss: () -> Void
    let onStopReminding: ((Int) -> Void)?

    init(
        prs: [PullRequest] = [],
        watchedPRs: [WatchedPR] = [],
        isReminder: Bool = false,
        onOpen: @escaping (PullRequest) -> Void = { _ in },
        onOpenWatched: @escaping (WatchedPR) -> Void = { _ in },
        onDismiss: @escaping () -> Void,
        onStopReminding: ((Int) -> Void)? = nil
    ) {
        self.prs = prs
        self.watchedPRs = watchedPRs
        self.isReminder = isReminder
        self.onOpen = onOpen
        self.onOpenWatched = onOpenWatched
        self.onDismiss = onDismiss
        self.onStopReminding = onStopReminding
    }

    private var displayCount: Int {
        isReminder ? watchedPRs.count : prs.count
    }

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
                Text("Press Escape or click anywhere to dismiss")
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
```

**Step 3: Add WatchedPRNotificationCard view**

Add after `PRNotificationCard`:

```swift
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
```

**Step 4: Update existing show method to use new signature**

Update the `show(for prs:)` method in `PRNotificationWindowController`:

```swift
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
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

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
```

**Step 5: Build and run tests**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | grep -E "(error:|passed|failed|BUILD)"`

Expected: All tests PASS

**Step 6: Commit**

```bash
git add pulse/pulseApp.swift
git commit -m "feat: update notification UI to support reminders"
```

---

## Task 7: Add Settings UI for Review Reminders

**Files:**
- Modify: `pulse/ContentView.swift`

**Step 1: Update NotificationsTabView**

Add reminder settings section to `NotificationsTabView`. Find the end of the polling settings section and add:

```swift
                Divider()

                // Review Reminders section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review Reminders")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Enable review reminders", isOn: $gitHubService.isReminderEnabled)

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
```

**Step 2: Add reminderMinutes state binding**

Update the `NotificationsTabView` to include a new state variable. Find the `@Binding var pollingMinutes` line and add after it:

```swift
    @State private var reminderMinutes: Double = 10
```

**Step 3: Initialize reminderMinutes in onAppear**

Update the `.onAppear` modifier:

```swift
        .onAppear {
            pollingMinutes = gitHubService.pollingInterval / 60
            reminderMinutes = gitHubService.reminderInterval / 60
        }
```

**Step 4: Build and verify**

Run: `xcodebuild -scheme pulse -configuration Debug build 2>&1 | grep -E "(error:|BUILD)"`

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add pulse/ContentView.swift
git commit -m "feat: add settings UI for review reminders"
```

---

## Task 8: Initialize Reminder Polling on App Start

**Files:**
- Modify: `pulse/GitHubService.swift`

**Step 1: Start reminder polling after loading watched PRs**

Update `loadWatchedPRs()` to start polling if there are watched PRs:

```swift
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
```

**Step 2: Handle isReminderEnabled changes**

Update `isReminderEnabled` property to manage polling:

```swift
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
```

**Step 3: Handle reminderInterval changes**

Update `reminderInterval` property to restart polling with new interval:

```swift
    var reminderInterval: TimeInterval = 600 {
        didSet {
            UserDefaults.standard.set(reminderInterval, forKey: "reminderInterval")
            // Restart polling with new interval if active
            if isReminderEnabled && !watchedPRs.isEmpty {
                startReminderPolling()
            }
        }
    }
```

**Step 4: Run all tests**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | grep -E "(passed|failed|error:)"`

Expected: All tests PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift
git commit -m "feat: initialize reminder polling on app start and handle settings changes"
```

---

## Task 9: Final Integration Test

**Files:**
- Manual testing

**Step 1: Build and run the app**

Run: `./run.sh`

**Step 2: Test the flow manually**

1. Click "Test Notification" in Settings → Notifications
2. When notification appears, click "Open PR"
3. Verify in Settings → Notifications that "Watching 1 PR" appears
4. Wait for reminder interval (or change to 1 minute for testing)
5. Verify reminder notification appears with yellow clock icon
6. Click "Stop Reminding" and verify PR is removed from watch list

**Step 3: Run full test suite**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | grep -E "(Test Suite|passed|failed)"`

Expected: All tests PASS

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete PR review reminders feature" --allow-empty
```

---

## Summary

This implementation adds:

1. **WatchedPR model** - Tracks PRs user has opened
2. **Watch list management** - Start/stop/clear watching
3. **GitHub API integration** - Check review status
4. **Reminder polling** - Background task checks every N minutes
5. **Updated notification UI** - Reminder mode with clock icon, "Stop Reminding" button
6. **Settings UI** - Toggle, interval slider, watched count display
7. **Persistence** - Survives app restarts via UserDefaults

Key behaviors:
- "Open PR" on notification → starts watching
- User submits review on GitHub → auto-stops watching
- PR closed/merged → auto-stops watching
- "Stop Reminding" → manual stop watching
