# Working Hours Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Suppress notifications and full-screen alerts outside user-defined per-day working hours, with queued catch-up when hours resume.

**Architecture:** Add `WorkingHoursSchedule` and `DaySchedule` Codable structs to GitHubService. Gate all three notification paths behind an `isWithinWorkingHours()` check. Queue suppressed notifications in UserDefaults and flush them on transition back into working hours. Update menu bar icon and show a popover banner when outside hours.

**Tech Stack:** SwiftUI, UserNotifications, UserDefaults, Calendar API

---

### Task 1: Data Model & Persistence

**Files:**
- Modify: `pulse/GitHubService.swift` (add structs near line 1571, add properties near line 80, add to loadSettings near line 144)
- Test: `pulseTests/pulseTests.swift`

**Step 1: Write the failing test**

Add to `pulseTests/pulseTests.swift`:

```swift
final class WorkingHoursTests: XCTestCase {
    func testDefaultSchedule() {
        let schedule = WorkingHoursSchedule.defaultSchedule()
        XCTAssertTrue(schedule.isEnabled)
        // Monday (weekday 2) should be enabled 9-17
        let monday = schedule.days[2]!
        XCTAssertTrue(monday.isEnabled)
        XCTAssertEqual(monday.startHour, 9)
        XCTAssertEqual(monday.startMinute, 0)
        XCTAssertEqual(monday.endHour, 17)
        XCTAssertEqual(monday.endMinute, 0)
        // Sunday (weekday 1) should be disabled
        let sunday = schedule.days[1]!
        XCTAssertFalse(sunday.isEnabled)
        // Saturday (weekday 7) should be disabled
        let saturday = schedule.days[7]!
        XCTAssertFalse(saturday.isEnabled)
    }

    func testScheduleEncodingRoundtrip() throws {
        let schedule = WorkingHoursSchedule.defaultSchedule()
        let data = try JSONEncoder().encode(schedule)
        let decoded = try JSONDecoder().decode(WorkingHoursSchedule.self, from: data)
        XCTAssertEqual(decoded.isEnabled, schedule.isEnabled)
        XCTAssertEqual(decoded.days.count, schedule.days.count)
        XCTAssertEqual(decoded.days[2]!.startHour, 9)
    }

    func testDayScheduleContainsTime() {
        let day = DaySchedule(isEnabled: true, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
        // 10:30 is within 9:00-17:00
        XCTAssertTrue(day.containsTime(hour: 10, minute: 30))
        // 8:59 is before
        XCTAssertFalse(day.containsTime(hour: 8, minute: 59))
        // 17:00 is at boundary (end is exclusive)
        XCTAssertFalse(day.containsTime(hour: 17, minute: 0))
        // 16:59 is just inside
        XCTAssertTrue(day.containsTime(hour: 16, minute: 59))
    }

    func testDisabledDayNeverContainsTime() {
        let day = DaySchedule(isEnabled: false, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
        XCTAssertFalse(day.containsTime(hour: 12, minute: 0))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WorkingHoursTests test 2>&1 | tail -20`
Expected: FAIL - `WorkingHoursSchedule` and `DaySchedule` not found

**Step 3: Write minimal implementation**

Add to `pulse/GitHubService.swift` near line 1571 (before `MyPRNotificationSettings`):

```swift
// MARK: - Working Hours

struct DaySchedule: Codable, Equatable {
    var isEnabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    func containsTime(hour: Int, minute: Int) -> Bool {
        guard isEnabled else { return false }
        let timeMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + self.startMinute
        let endMinutes = endHour * 60 + self.endMinute
        return timeMinutes >= startMinutes && timeMinutes < endMinutes
    }
}

struct WorkingHoursSchedule: Codable {
    var isEnabled: Bool
    var days: [Int: DaySchedule]  // 1=Sunday..7=Saturday (Calendar weekday)

    static func defaultSchedule() -> WorkingHoursSchedule {
        let weekday = DaySchedule(isEnabled: true, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
        let weekend = DaySchedule(isEnabled: false, startHour: 9, startMinute: 0, endHour: 17, endMinute: 0)
        return WorkingHoursSchedule(
            isEnabled: true,
            days: [
                1: weekend,  // Sunday
                2: weekday,  // Monday
                3: weekday,  // Tuesday
                4: weekday,  // Wednesday
                5: weekday,  // Thursday
                6: weekday,  // Friday
                7: weekend   // Saturday
            ]
        )
    }
}
```

Add property to `GitHubService` class (near line 80, after the review reminders section):

```swift
// Working hours
var workingHoursSchedule: WorkingHoursSchedule = WorkingHoursSchedule.defaultSchedule() {
    didSet { saveWorkingHoursSchedule() }
}
var isWorkingHoursOverridden: Bool = false  // "Resume now" temporary override
```

Add persistence methods (near the existing `saveMyPRNotificationSettings`/`loadMyPRNotificationSettings`):

```swift
private func saveWorkingHoursSchedule() {
    if let data = try? JSONEncoder().encode(workingHoursSchedule) {
        UserDefaults.standard.set(data, forKey: "workingHoursSchedule")
    }
}

private func loadWorkingHoursSchedule() {
    if let data = UserDefaults.standard.data(forKey: "workingHoursSchedule"),
       let schedule = try? JSONDecoder().decode(WorkingHoursSchedule.self, from: data) {
        workingHoursSchedule = schedule
    }
}
```

Add `loadWorkingHoursSchedule()` call in `loadSettings()` (after line 170).

Add the core check method:

```swift
func isWithinWorkingHours() -> Bool {
    guard workingHoursSchedule.isEnabled else { return true }
    if isWorkingHoursOverridden { return true }
    let now = Calendar.current.dateComponents([.weekday, .hour, .minute], from: Date())
    guard let weekday = now.weekday, let hour = now.hour, let minute = now.minute,
          let daySchedule = workingHoursSchedule.days[weekday] else { return true }
    return daySchedule.containsTime(hour: hour, minute: minute)
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WorkingHoursTests test 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: Add WorkingHoursSchedule data model and persistence"
```

---

### Task 2: Notification Queuing & Suppression

**Files:**
- Modify: `pulse/GitHubService.swift` (lines 185-216 sendNotification, lines 766-821 sendMyPRNotifications, line 1287-1291 sendReminderNotification)
- Test: `pulseTests/pulseTests.swift`

**Step 1: Write the failing test**

Add to `WorkingHoursTests`:

```swift
func testQueuedNotificationEncodingRoundtrip() throws {
    let queued = QueuedPRNotification(prId: 123, prTitle: "Fix bug", prRepository: "org/repo", prURL: "https://github.com/org/repo/pull/1", queuedAt: Date())
    let data = try JSONEncoder().encode([queued])
    let decoded = try JSONDecoder().decode([QueuedPRNotification].self, from: data)
    XCTAssertEqual(decoded.first?.prId, 123)
    XCTAssertEqual(decoded.first?.prTitle, "Fix bug")
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/WorkingHoursTests/testQueuedNotificationEncodingRoundtrip test 2>&1 | tail -20`
Expected: FAIL - `QueuedPRNotification` not found

**Step 3: Write minimal implementation**

Add `QueuedPRNotification` struct near the other Working Hours types:

```swift
struct QueuedPRNotification: Codable, Equatable {
    let prId: Int
    let prTitle: String
    let prRepository: String
    let prURL: String
    let queuedAt: Date
}
```

Add properties to `GitHubService` (near the working hours properties):

```swift
var queuedNotifications: [QueuedPRNotification] = [] {
    didSet { saveQueuedNotifications() }
}
private var wasOutsideWorkingHours: Bool = true
private var workingHoursCheckTask: Task<Void, Never>?
```

Add persistence for queued notifications:

```swift
private func saveQueuedNotifications() {
    if let data = try? JSONEncoder().encode(queuedNotifications) {
        UserDefaults.standard.set(data, forKey: "queuedNotifications")
    }
}

private func loadQueuedNotifications() {
    if let data = UserDefaults.standard.data(forKey: "queuedNotifications"),
       let queued = try? JSONDecoder().decode([QueuedPRNotification].self, from: data) {
        queuedNotifications = queued
    }
}
```

Add `loadQueuedNotifications()` to `loadSettings()`.

Gate `sendNotification(for:)` (line 185). Replace the method body:

```swift
func sendNotification(for newPRs: [PullRequest]) {
    guard !newPRs.isEmpty else { return }

    if !isWithinWorkingHours() {
        // Queue for later
        for pr in newPRs {
            let queued = QueuedPRNotification(
                prId: pr.id, prTitle: pr.title,
                prRepository: pr.repository, prURL: pr.htmlURL,
                queuedAt: Date()
            )
            if !queuedNotifications.contains(where: { $0.prId == pr.id }) {
                queuedNotifications.append(queued)
            }
        }
        return
    }

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
            identifier: "pr-\(pr.id)", content: content, trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                print("[Pulse] Notification error: \(error.localizedDescription)")
            }
        }
    }
}
```

Gate `sendMyPRNotifications` (line 814). Wrap the `if shouldNotify` block:

```swift
if shouldNotify {
    if self.isWithinWorkingHours() {
        await MainActor.run {
            sendSystemNotification(title: title, body: body, prURL: pr.htmlURL)
        }
    }
    // My PR activity notifications don't queue (too noisy on catch-up)
}
```

Gate `sendReminderNotification` (line 1287):

```swift
func sendReminderNotification(for watchedPRs: [WatchedPR]) {
    guard isWithinWorkingHours() else { return }
    DispatchQueue.main.async {
        PRNotificationWindowController.shared.showReminder(for: watchedPRs)
    }
}
```

Add the working hours transition checker. Start it from `startPolling()`:

```swift
private func startWorkingHoursCheck() {
    workingHoursCheckTask?.cancel()
    guard workingHoursSchedule.isEnabled else { return }

    wasOutsideWorkingHours = !isWithinWorkingHours()

    workingHoursCheckTask = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 1 minute
            let currentlyInside = isWithinWorkingHours()

            if currentlyInside && wasOutsideWorkingHours {
                // Transition: outside → inside working hours
                await flushQueuedNotifications()
            }
            wasOutsideWorkingHours = !currentlyInside
        }
    }
}

private func flushQueuedNotifications() async {
    guard !queuedNotifications.isEmpty else { return }
    let queued = queuedNotifications
    queuedNotifications = []

    let center = UNUserNotificationCenter.current()
    for notification in queued {
        let content = UNMutableNotificationContent()
        content.title = "New PR Review Request"
        content.subtitle = notification.prRepository
        content.body = notification.prTitle
        content.sound = .default
        content.userInfo = ["prURL": notification.prURL]
        let request = UNNotificationRequest(
            identifier: "pr-queued-\(notification.prId)", content: content, trigger: nil
        )
        center.add(request) { error in
            if let error = error {
                print("[Pulse] Queued notification error: \(error.localizedDescription)")
            }
        }
    }
}
```

Call `startWorkingHoursCheck()` at end of `startPolling()` method (line 357).
Cancel `workingHoursCheckTask` in `deinit` (line 179) and `signOut()` (line 319).

**Step 4: Run tests to verify everything passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: Gate notifications behind working hours with queuing"
```

---

### Task 3: Menu Bar Icon Indicator

**Files:**
- Modify: `pulse/pulseApp.swift` (lines 44-52)
- Modify: `pulse/GitHubService.swift`

**Step 1: Add an observable property for icon state**

In `GitHubService`, add a computed or updated property:

```swift
var isOutsideWorkingHours: Bool {
    workingHoursSchedule.isEnabled && !isWorkingHoursOverridden && !isWithinWorkingHours()
}
```

**Step 2: Update AppDelegate to observe and switch icons**

In `pulseApp.swift`, in `AppDelegate`, add an observation task. After the popover setup (around line 59), add:

```swift
// Observe working hours status for icon changes
workingHoursObservation = Task { @MainActor in
    let service = GitHubService.shared
    while !Task.isCancelled {
        let outsideHours = service.isOutsideWorkingHours
        if let button = statusItem?.button {
            let iconName = outsideHours ? "moon.zzz" : "waveform.path.ecg"
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Pulse")
            button.image?.isTemplate = true
        }
        try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // Check every 30s
    }
}
```

Add the property to `AppDelegate`:

```swift
private var workingHoursObservation: Task<Void, Never>?
```

**Step 3: Build and verify**

Run: `xcodebuild -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add pulse/pulseApp.swift pulse/GitHubService.swift
git commit -m "feat: Show moon icon in menu bar outside working hours"
```

---

### Task 4: Popover Banner

**Files:**
- Modify: `pulse/ContentView.swift` (insert after line 264 Divider, before line 267 tabContent)

**Step 1: Add the banner view**

In `PRListView`, add a computed property for the next start time display and the banner:

```swift
private var workingHoursBanner: some View {
    Group {
        if gitHubService.isOutsideWorkingHours {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Notifications paused until \(nextWorkingHoursStart)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Resume now") {
                    gitHubService.isWorkingHoursOverridden = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
        }
    }
}

private var nextWorkingHoursStart: String {
    let schedule = gitHubService.workingHoursSchedule
    let calendar = Calendar.current
    let now = Date()

    // Check today and next 7 days for the next enabled day
    for dayOffset in 0..<8 {
        guard let checkDate = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
        let weekday = calendar.component(.weekday, from: checkDate)
        guard let daySchedule = schedule.days[weekday], daySchedule.isEnabled else { continue }

        var components = calendar.dateComponents([.year, .month, .day], from: checkDate)
        components.hour = daySchedule.startHour
        components.minute = daySchedule.startMinute
        guard let startDate = calendar.date(from: components) else { continue }

        if startDate > now {
            let formatter = DateFormatter()
            // If it's today, show just time; otherwise show day + time
            if dayOffset == 0 {
                formatter.dateFormat = "HH:mm"
            } else {
                formatter.dateFormat = "EEE HH:mm"
            }
            return formatter.string(from: startDate)
        }
    }
    return "next working day"
}
```

Insert `workingHoursBanner` in `mainContent` between the Divider (line 264) and `tabContent` (line 267):

```swift
Divider()

workingHoursBanner

// Per-tab loading and content
tabContent
```

**Step 2: Build and verify**

Run: `xcodebuild -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add pulse/ContentView.swift
git commit -m "feat: Show notification paused banner outside working hours"
```

---

### Task 5: Settings UI

**Files:**
- Modify: `pulse/ContentView.swift` (NotificationsTabView, insert between Auto-Refresh section ending at line 874 and Review Reminders starting at line 878)

**Step 1: Add the Working Hours settings section**

In `NotificationsTabView`, add a `@State` for time picker dates. Near the existing `@State private var pollingMinutes` and `reminderMinutes`:

```swift
@State private var daySchedules: [Int: DaySchedule] = [:]
```

Add the section between Auto-Refresh Divider (line 876) and Review Reminders (line 878):

```swift
// Working Hours section
VStack(alignment: .leading, spacing: 12) {
    Text("Working Hours")
        .font(.subheadline)
        .foregroundStyle(.secondary)

    Toggle("Enable working hours", isOn: $gitHubService.workingHoursSchedule.isEnabled)

    Text("Suppress notifications and full-screen alerts outside your working hours. Queued notifications will be delivered when working hours start.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    if gitHubService.workingHoursSchedule.isEnabled {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                if let daySchedule = gitHubService.workingHoursSchedule.days[weekday] {
                    WorkingHoursDayRow(
                        dayName: dayName(for: weekday),
                        schedule: Binding(
                            get: { gitHubService.workingHoursSchedule.days[weekday] ?? daySchedule },
                            set: { gitHubService.workingHoursSchedule.days[weekday] = $0 }
                        )
                    )
                }
            }
        }

        Button("Apply Monday to all weekdays") {
            if let monday = gitHubService.workingHoursSchedule.days[2] {
                for weekday in 3...6 {
                    gitHubService.workingHoursSchedule.days[weekday] = DaySchedule(
                        isEnabled: monday.isEnabled,
                        startHour: monday.startHour, startMinute: monday.startMinute,
                        endHour: monday.endHour, endMinute: monday.endMinute
                    )
                }
            }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .foregroundStyle(.blue)

        if gitHubService.isWorkingHoursOverridden {
            HStack {
                Text("Working hours manually resumed for this session")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Reset") {
                    gitHubService.isWorkingHoursOverridden = false
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }
}

Divider()
```

Add the helper `dayName` function to `NotificationsTabView`:

```swift
private func dayName(for weekday: Int) -> String {
    let formatter = DateFormatter()
    return formatter.shortWeekdaySymbols[weekday - 1]  // 1-indexed to 0-indexed
}
```

Add `WorkingHoursDayRow` as a separate view (can be added at end of ContentView.swift):

```swift
struct WorkingHoursDayRow: View {
    let dayName: String
    @Binding var schedule: DaySchedule

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $schedule.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Text(dayName)
                .font(.caption)
                .frame(width: 32, alignment: .leading)

            if schedule.isEnabled {
                HStack(spacing: 4) {
                    TimePickerCompact(hour: $schedule.startHour, minute: $schedule.startMinute)
                    Text("–")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TimePickerCompact(hour: $schedule.endHour, minute: $schedule.endMinute)
                }
            } else {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

struct TimePickerCompact: View {
    @Binding var hour: Int
    @Binding var minute: Int

    var body: some View {
        HStack(spacing: 2) {
            Picker("", selection: $hour) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d", h)).tag(h)
                }
            }
            .frame(width: 50)
            .labelsHidden()

            Text(":")
                .font(.caption)

            Picker("", selection: $minute) {
                ForEach(Array(stride(from: 0, to: 60, by: 15)), id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .frame(width: 50)
            .labelsHidden()
        }
    }
}
```

**Step 2: Build and verify**

Run: `xcodebuild -scheme pulse -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Run all tests**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add pulse/ContentView.swift
git commit -m "feat: Add Working Hours settings UI with per-day schedule"
```

---

### Task 6: Final Integration Test

**Step 1: Run full test suite**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | tail -30`
Expected: ALL PASS

**Step 2: Build release**

Run: `./build.sh`
Expected: DMG created successfully

**Step 3: Commit any remaining fixes, then tag**

```bash
git tag v0.2.0
```
