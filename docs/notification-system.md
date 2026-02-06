# Pulse Notification System

## Overview

Pulse has two notification systems:
1. **New PR Notifications** - Alert when new PRs where **you are personally requested** as a reviewer
2. **Review Reminders** - Remind you about PRs you opened but haven't reviewed yet

### What triggers New PR Notifications?

| Scenario | Notified? |
|----------|-----------|
| Someone requests **your** review specifically | ✅ Yes |
| PR assigned to your **team** | ❌ No (unless you're also requested) |
| PR in a repo you watch | ❌ No |
| PR you're mentioned in | ❌ No |
| PR you commented on | ❌ No |

The GitHub API query: `review-requested:{your_username}`

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PULSE APP                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐         ┌──────────────────┐                          │
│  │   PR Polling     │         │ Reminder Polling │                          │
│  │  (5 min default) │         │ (10 min default) │                          │
│  └────────┬─────────┘         └────────┬─────────┘                          │
│           │                            │                                     │
│           ▼                            ▼                                     │
│  ┌──────────────────┐         ┌──────────────────┐                          │
│  │ fetchAllPRs()    │         │ checkWatchedPRs()│                          │
│  │ - Awaiting Review│         │                  │                          │
│  │ - Involved       │         │                  │                          │
│  │ - My PRs         │         │                  │                          │
│  └────────┬─────────┘         └────────┬─────────┘                          │
│           │                            │                                     │
│           ▼                            ▼                                     │
│  ┌──────────────────┐         ┌──────────────────┐                          │
│  │ Compare with     │         │ Check PR status  │                          │
│  │ previousPRIds    │         │ via GitHub API   │                          │
│  └────────┬─────────┘         └────────┬─────────┘                          │
│           │                            │                                     │
│     New PRs?                     Needs reminder?                             │
│       │ YES                          │ YES                                   │
│       ▼                              ▼                                       │
│  ┌──────────────────────────────────────────────────────────────┐           │
│  │              PRNotificationWindowController                   │           │
│  │                  (Full-screen overlay)                        │           │
│  └──────────────────────────────────────────────────────────────┘           │
│                              │                                               │
│                              ▼                                               │
│                    ┌──────────────────┐                                      │
│                    │  User Actions:   │                                      │
│                    │  • Open PR       │                                      │
│                    │  • Snooze 5 min  │                                      │
│                    │  • Review Later  │                                      │
│                    │  • Dismiss       │                                      │
│                    └──────────────────┘                                      │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## New PR Notification Flow

```mermaid
flowchart TD
    A[App Start / Poll Timer] --> B[fetchAllPRs]
    B --> C[GitHub Search API]
    C --> D{First load?}
    D -->|Yes| E[Store PR IDs]
    D -->|No| F{New PRs found?}
    F -->|No| G[Update UI]
    F -->|Yes| H[Show Full-Screen Notification]
    H --> I{User Action}
    I -->|Open PR| J[Open in Browser + Start Watching]
    I -->|Snooze 5min| K[Add to Snoozed List]
    I -->|Review Later| L[Start Watching]
    I -->|Dismiss| M[Add to Dismissed List]
    E --> G
    J --> G
    K --> G
    L --> G
    M --> G
    G --> N[Wait 5 minutes]
    N --> B
```

---

## Review Reminder Flow

```mermaid
flowchart TD
    A[User clicks 'Open PR' or 'Review Later'] --> B[startWatching]
    B --> C[Add to watchedPRs]
    C --> D[Start Reminder Polling]

    D --> E[Wait reminder interval]
    E --> F[checkWatchedPRs]

    F --> G{For each watched PR}
    G --> H{Snoozed?}
    H -->|Yes| G
    H -->|No| I[Check PR status via API]

    I --> J{Status?}
    J -->|Approved by user| K[Remove from watched]
    J -->|PR Closed/Merged| K
    J -->|Waiting for author| L[Skip reminder]
    J -->|Needs review| M[Add to reminder list]

    L --> G
    M --> G
    K --> G

    G -->|Done| N{Any need reminder?}
    N -->|Yes| O[Show Reminder Notification]
    N -->|No| P{Any still watched?}

    O --> P
    P -->|Yes| E
    P -->|No| Q[Stop Reminder Polling]
```

---

## Watched PR Status States

```mermaid
stateDiagram-v2
    [*] --> Watching: User opens/reviews later

    Watching --> NeedsReminder: Reminder interval passed
    Watching --> Snoozed: User clicks snooze

    Snoozed --> NeedsReminder: Snooze expired

    NeedsReminder --> Watching: After reminder shown
    NeedsReminder --> Approved: User submitted approval
    NeedsReminder --> Closed: PR closed/merged

    Approved --> [*]: Auto-removed
    Closed --> [*]: Auto-removed
```

---

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| Polling Interval | 5 min | How often to check for new PRs |
| Reminder Interval | 10 min | How often to remind about unreviewed PRs |
| Polling Enabled | Yes | Enable/disable auto-refresh |
| Reminders Enabled | Yes | Enable/disable review reminders |

---

## My PRs Activity Notifications

For PRs you authored, Pulse tracks activity changes:

```mermaid
flowchart LR
    A[Poll My PRs] --> B[Fetch PR Activity]
    B --> C{Activity changed?}
    C -->|Approvals| D[Notify if enabled]
    C -->|Comments| D
    C -->|CI Status| D
    C -->|Merges| D
    C -->|Conflicts| D
    D --> E[System Notification]
```

Each notification type can be individually enabled/disabled in Settings.
