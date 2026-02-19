# Working Hours Feature Design

## Overview

Allow users to define per-day working hours. Outside these hours, notifications and full-screen alerts are suppressed while polling continues. When working hours resume, queued notifications fire individually.

## Data Model

```swift
struct DaySchedule: Codable {
    var isEnabled: Bool       // false = no notifications this day
    var startHour: Int        // 0-23
    var startMinute: Int      // 0-59
    var endHour: Int          // 0-23
    var endMinute: Int        // 0-59
}

struct WorkingHoursSchedule: Codable {
    var isEnabled: Bool                      // master toggle
    var days: [Int: DaySchedule]             // 1=Sunday..7=Saturday (Calendar weekday)
}
```

**Defaults**: Enabled, Mon-Fri 9:00-17:00, weekends disabled.

**Persistence**: Encoded to UserDefaults, same pattern as `myPRNotificationSettings`.

## Notification Suppression & Catch-up

### Core Logic

`isWithinWorkingHours() -> Bool` on `GitHubService` checks current time against today's schedule.

### Suppression Points

All three notification paths check `isWithinWorkingHours()` before firing:

1. `sendNotification(for:)` - system notifications for new review requests
2. `showFullScreenNotification(for:)` - full-screen overlay alerts
3. My PR activity notifications (approvals, comments, etc.)

### Queuing

When a notification is suppressed, the PR ID / activity event is added to a `queuedNotifications` set persisted to UserDefaults (survives app restart overnight).

### Resuming

A lightweight timer checks once per minute if we've transitioned into working hours. On transition:

1. Fire individual notifications for each queued PR
2. Clear the queue
3. Update `previousPRIds` so the next poll cycle doesn't re-notify

## Visual Indicators

### Menu Bar Icon

When outside working hours, change the status item icon to a "moon" variant (e.g. `moon.zzz`) to signal notifications are paused. Revert to normal icon when working hours resume.

### Popover Banner

When the popover opens outside working hours, show a subtle info banner at the top:

- Muted styling, small horizontal bar
- Text: "Notifications paused until 9:00" (next start time)
- "Resume now" button to temporarily override for the current session

## Settings UI

New section in the Notifications settings tab, between "Auto-Refresh" and "Review Reminders".

### Layout

- **Master toggle**: "Working Hours" on/off
- **Day rows**: 7 rows (Mon-Sun display order), each with:
  - Checkbox to enable/disable the day
  - Two `DatePicker` (`.hourAndMinute` style) for start/end times, disabled when day is unchecked
- **Quick action**: "Apply to weekdays" button copies Monday's schedule to Tue-Fri

## Implementation Scope

### Files to Modify

- `pulse/GitHubService.swift` - data model, schedule logic, notification gating, queue management
- `pulse/ContentView.swift` - settings UI section, popover banner
- `pulse/pulseApp.swift` - menu bar icon switching

### Not in Scope

- Per-timezone support (uses device local time)
- Multiple schedule profiles
- Calendar integration
