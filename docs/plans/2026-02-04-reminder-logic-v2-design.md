# Reminder Logic v2 Design

## Problem

Current implementation has two issues:

1. **Immediate reminder** - Reminder shows immediately after clicking "Open PR", should wait for interval first
2. **Premature removal** - PR disappears from watched list when user submits ANY review (APPROVED, CHANGES_REQUESTED, COMMENTED), but should only disappear on APPROVED

## New Logic

### When to Remove from watchedPRs

| Condition | Action |
|-----------|--------|
| PR closed/merged | Remove from list |
| User submitted APPROVED | Remove from list |
| User submitted CHANGES_REQUESTED | Keep on list (pause reminders) |
| User submitted COMMENTED | Keep on list (pause reminders) |
| No review yet | Keep on list (keep reminding) |

### When to Show Reminders

```
IF no review submitted yet:
    → Remind (after initial delay)

IF review is CHANGES_REQUESTED or COMMENTED:
    → Check if author responded (new commits after review)
    → If author responded: Resume reminders
    → If waiting for author: Pause reminders

IF review is APPROVED:
    → Remove from list (no reminders)
```

### First Reminder Delay

Don't show reminder immediately after "Open PR". Wait for the configured reminder interval before the first reminder.

**Implementation:** Check `startedWatchingAt` - only remind if `Date() - startedWatchingAt >= reminderInterval`

### Detecting Author Response

Compare timestamps:
- `lastReviewSubmittedAt` - when user submitted their review
- `PR.updatedAt` - when PR was last updated (includes new commits)

If `PR.updatedAt > lastReviewSubmittedAt` → Author has responded → Resume reminders

## Data Model Changes

### WatchedPR (updated)

```swift
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
    var lastReviewedAt: Date?      // NEW: when user last submitted review
    var lastReviewState: String?   // NEW: APPROVED, CHANGES_REQUESTED, COMMENTED
}
```

### WatchedPRStatus (updated)

```swift
enum WatchedPRStatus {
    case needsReminder          // No review yet, or author responded after review
    case waitingForAuthor       // NEW: User reviewed, waiting for author response
    case approved               // RENAMED from .reviewed
    case closed
}
```

## API Changes

### hasUserReviewedPR → getUserReviewStatus

Change from returning `Bool` to returning review details:

```swift
struct UserReviewStatus {
    let hasReviewed: Bool
    let state: String?           // APPROVED, CHANGES_REQUESTED, COMMENTED, nil
    let submittedAt: Date?
}

func getUserReviewStatus(owner: String, repo: String, number: Int) async -> UserReviewStatus
```

### checkWatchedPRStatus (updated logic)

```swift
func checkWatchedPRStatus(pr: WatchedPR) async -> WatchedPRStatus {
    // 1. Check if PR is still open
    guard let prDetails = await fetchPRDetails(...) else {
        return .closed
    }
    if prDetails.state != "open" {
        return .closed
    }

    // 2. Get user's review status
    let reviewStatus = await getUserReviewStatus(...)

    // 3. If approved → done
    if reviewStatus.state == "APPROVED" {
        return .approved
    }

    // 4. If reviewed (CHANGES_REQUESTED or COMMENTED)
    if let reviewedAt = reviewStatus.submittedAt {
        // Check if author responded (PR updated after review)
        if prDetails.updatedDate > reviewedAt {
            return .needsReminder  // Author responded, remind again
        } else {
            return .waitingForAuthor  // Still waiting
        }
    }

    // 5. No review yet
    return .needsReminder
}
```

## checkWatchedPRs (updated logic)

```swift
func checkWatchedPRs() async {
    var prsNeedingReminder: [WatchedPR] = []
    var prsToRemove: [Int] = []
    var prsToUpdate: [(Int, String?, Date?)] = []  // id, state, reviewedAt

    for pr in watchedPRs {
        // Skip if not enough time passed since watching started
        if Date().timeIntervalSince(pr.startedWatchingAt) < reminderInterval {
            continue
        }

        let status = await checkWatchedPRStatus(pr: pr)

        switch status {
        case .approved, .closed:
            prsToRemove.append(pr.id)
        case .waitingForAuthor:
            // Update review state but don't remind
            // (handled by getUserReviewStatus updating the WatchedPR)
            break
        case .needsReminder:
            prsNeedingReminder.append(pr)
        }
    }

    // Remove completed PRs
    for prId in prsToRemove {
        stopWatching(prId: prId)
    }

    // Send reminders
    if !prsNeedingReminder.isEmpty {
        sendReminderNotification(for: prsNeedingReminder)
    }
}
```

## Flow Diagram

```
┌─────────────────┐
│ User clicks     │
│ "Open PR"       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Add to          │
│ watchedPRs      │
│ startedWatchingAt = now
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────────┐
│           EVERY reminderInterval            │
└─────────────────────────────────────────────┘
         │
         ▼
┌─────────────────┐     No
│ Time since      │─────────────────┐
│ start >= interval?                │
└────────┬────────┘                 │
         │ Yes                      │
         ▼                          ▼
┌─────────────────┐         ┌─────────────────┐
│ Fetch PR status │         │ Skip (too early)│
└────────┬────────┘         └─────────────────┘
         │
         ▼
┌─────────────────┐
│ PR still open?  │───No───► REMOVE (closed)
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│ User review     │
│ status?         │
└────────┬────────┘
         │
    ┌────┴────┬──────────┬────────────┐
    ▼         ▼          ▼            ▼
┌────────┐ ┌────────┐ ┌──────────┐ ┌────────┐
│APPROVED│ │CHANGES │ │COMMENTED │ │ None   │
└───┬────┘ │REQUESTED│ └────┬─────┘ └───┬────┘
    │      └────┬────┘      │           │
    ▼           └─────┬─────┘           │
 REMOVE               ▼                 │
 (done!)     ┌────────────────┐         │
             │ Author responded│         │
             │ (PR updated     │         │
             │  after review)? │         │
             └───────┬────────┘         │
                ┌────┴────┐             │
                ▼         ▼             │
              Yes        No             │
                │         │             │
                ▼         ▼             │
           ┌────────┐ ┌────────┐        │
           │REMIND  │ │WAIT    │        │
           └────────┘ │(silent)│        │
                      └────────┘        │
                                        ▼
                                   ┌────────┐
                                   │REMIND  │
                                   └────────┘
```

## Implementation Tasks

1. Update `WatchedPR` model with `lastReviewedAt` and `lastReviewState`
2. Update `WatchedPRStatus` enum (add `.waitingForAuthor`, rename `.reviewed` to `.approved`)
3. Create `getUserReviewStatus()` function returning review details
4. Update `checkWatchedPRStatus()` with new logic
5. Update `checkWatchedPRs()` to skip PRs within initial delay
6. Update tests for new behavior
