# PR Review Reminders Design

## Overview

Add persistent reminder functionality for PRs that the user has opened but not yet reviewed. When a user clicks "Open PR" on a notification, Pulse will track that PR and periodically check if a review has been submitted. If not, it will show a reminder notification.

## User Flow

1. New PR notification appears (existing behavior)
2. User clicks "Open PR" → PR opens in browser AND is added to watch list
3. Every N minutes, Pulse checks if user has submitted a review
4. If no review found → show reminder notification
5. User can:
   - **Dismiss** - closes notification, will remind again next interval
   - **Stop Reminding** - removes PR from watch list
   - **Open PR** - opens PR again (stays in watch list)
6. Once review detected (or PR closed/merged) → automatically stop watching

## Data Model

### WatchedPR

```swift
struct WatchedPR: Codable, Identifiable {
    let id: Int           // Same as PR id
    let prNumber: Int
    let owner: String     // Repository owner
    let repo: String      // Repository name
    let repository: String // "owner/repo" format
    let title: String
    let htmlURL: String
    let authorLogin: String
    let authorAvatarURL: String
    let startedWatchingAt: Date
    var lastReminderAt: Date?
}
```

### Storage

- New property in `GitHubService`: `var watchedPRs: [WatchedPR] = []`
- Persisted to UserDefaults as JSON
- Key: `"watchedPRs"`
- Loaded on init, saved on any change via `didSet`

### Settings

- `isReminderEnabled: Bool` - default `true`, stored in UserDefaults
- `reminderInterval: TimeInterval` - default 600 (10 minutes), stored in UserDefaults

## GitHub API Integration

### Check Review Status

**Endpoint:** `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`

**Response filtering:**
- Find reviews where `user.login == currentUser.login`
- Review states that count as "reviewed":
  - `APPROVED`
  - `CHANGES_REQUESTED`
  - `COMMENTED`
- `PENDING` does not count (draft review)

### Check PR Status

While checking reviews, also verify PR is still open:
- If PR state is `closed` or `merged` → stop watching

### New Methods

```swift
// Check if current user has submitted a review
func hasUserReviewedPR(owner: String, repo: String, number: Int) async -> Bool

// Check if PR is still open
func isPROpen(owner: String, repo: String, number: Int) async -> Bool

// Combined check for reminder logic
func checkWatchedPRStatus(pr: WatchedPR) async -> WatchedPRStatus

enum WatchedPRStatus {
    case needsReminder
    case reviewed
    case closed
}
```

## Reminder Polling

### Implementation

- New `reminderPollingTask: Task<Void, Never>?` in GitHubService
- Separate from main PR polling task
- Only runs when `watchedPRs` is non-empty AND `isReminderEnabled`

### Polling Logic

```
func checkWatchedPRs() async {
    var prsNeedingReminder: [WatchedPR] = []

    for pr in watchedPRs {
        let status = await checkWatchedPRStatus(pr: pr)

        switch status {
        case .reviewed, .closed:
            stopWatching(prId: pr.id)
        case .needsReminder:
            prsNeedingReminder.append(pr)
        }
    }

    if !prsNeedingReminder.isEmpty {
        sendReminderNotification(for: prsNeedingReminder)
        updateLastReminderTimestamps(for: prsNeedingReminder)
    }
}
```

### Start/Stop Logic

- Start reminder polling when first PR is added to watch list
- Stop reminder polling when watch list becomes empty
- Restart with new interval if settings change

## UI Changes

### FullScreenPRNotificationView

Add `isReminder: Bool` parameter (default: `false`).

**When `isReminder == true`:**
- Icon: `clock.badge.exclamationmark` instead of `bell.badge.fill`
- Header: "Review Reminder" instead of "New PR Review Request"
- Subtext: "You opened this X minutes ago" with relative time
- Buttons: "Dismiss" | "Stop Reminding" | "Open PR"

### PRNotificationWindowController

- New method: `showReminder(for prs: [WatchedPR])`
- Converts `WatchedPR` to display format
- Passes `isReminder: true` to view

### Notification Actions

| Button | Action |
|--------|--------|
| Dismiss | Close notification, will remind again next interval |
| Stop Reminding | Remove PR from watchedPRs, close notification |
| Open PR | Open URL in browser, close notification (stays watched) |

### Settings - Notifications Tab

Add new section "Review Reminders":

```swift
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

            Slider(value: $reminderMinutes, in: 5...60, step: 5)
        }

        if !gitHubService.watchedPRs.isEmpty {
            HStack {
                Text("Watching \(gitHubService.watchedPRs.count) PR(s)")
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

## Implementation Tasks

1. **Add WatchedPR model and storage**
   - Define `WatchedPR` struct
   - Add `watchedPRs` property with persistence
   - Add `isReminderEnabled` and `reminderInterval` settings

2. **Add watch list management methods**
   - `startWatching(pr: PullRequest)`
   - `stopWatching(prId: Int)`
   - `clearAllWatchedPRs()`
   - `isWatching(prId: Int) -> Bool`

3. **Add GitHub API methods for review checking**
   - `hasUserReviewedPR(owner:repo:number:)`
   - `checkWatchedPRStatus(pr:)`

4. **Implement reminder polling**
   - `reminderPollingTask` property
   - `startReminderPolling()` / `stopReminderPolling()`
   - `checkWatchedPRs()` async method

5. **Update notification UI**
   - Add `isReminder` parameter to `FullScreenPRNotificationView`
   - Add "Stop Reminding" button
   - Update header/icon for reminder mode
   - Show time since opened

6. **Update PRNotificationWindowController**
   - Add `showReminder(for:)` method
   - Handle "Stop Reminding" action

7. **Wire up "Open PR" to start watching**
   - Modify `onOpen` closure in notification view
   - Call `startWatching` before opening URL

8. **Add settings UI**
   - New "Review Reminders" section in Notifications tab
   - Toggle, interval slider, watched count display

9. **Add tests**
   - WatchedPR encoding/decoding
   - Watch list management
   - Review status parsing

## API Rate Limiting Considerations

- GitHub API rate limit: 5000 requests/hour for authenticated users
- Each watched PR check = 1-2 API calls (reviews + optionally PR status)
- With 10 watched PRs checked every 10 minutes = 60-120 calls/hour
- Well within limits, but should batch or optimize if watch list grows large

## Future Enhancements (Out of Scope)

- Escalating reminder intervals
- Priority based on PR age
- Menu bar badge showing watched PR count
- Snooze functionality ("remind me in 1 hour")
