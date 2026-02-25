# CI Status Notifications Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fetch CI check run status from GitHub for My PRs and trigger notifications on failure/success.

**Architecture:** Add `sha` to `PRBranch` model, call GitHub Checks API (`GET /repos/{owner}/{repo}/commits/{sha}/check-runs`) in `fetchPRActivity()`, derive overall status, feed into existing `detectActivityChanges` → `sendMyPRNotifications` pipeline which already handles `.checkFailure`/`.checkSuccess` events.

**Tech Stack:** Swift 6, SwiftUI, GitHub REST API v3 (Checks API)

---

### Task 1: Add `sha` field to PRBranch model

**Files:**
- Modify: `pulse/GitHubService.swift:1588-1591` (PRBranch struct)
- Test: `pulseTests/pulseTests.swift`

**Step 1: Write the failing test**

In `pulseTests/pulseTests.swift`, add a new test class after `ReReviewDetectionTests`:

```swift
// MARK: - CI Status Tests

final class CIStatusTests: XCTestCase {

    func testPRBranchDecodesSha() throws {
        let json = """
        {
            "ref": "feature-branch",
            "sha": "abc123def456",
            "repo": {
                "name": "Hello-World",
                "full_name": "octocat/Hello-World"
            }
        }
        """.data(using: .utf8)!

        let branch = try JSONDecoder().decode(PRBranch.self, from: json)
        XCTAssertEqual(branch.sha, "abc123def456")
        XCTAssertEqual(branch.ref, "feature-branch")
    }

    func testPRBranchDecodesWithoutSha() throws {
        let json = """
        {
            "ref": "feature-branch",
            "repo": {
                "name": "Hello-World",
                "full_name": "octocat/Hello-World"
            }
        }
        """.data(using: .utf8)!

        let branch = try JSONDecoder().decode(PRBranch.self, from: json)
        XCTAssertNil(branch.sha)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/CIStatusTests test 2>&1 | tail -20`
Expected: FAIL — `PRBranch` has no member `sha`

**Step 3: Add `sha` to PRBranch**

In `pulse/GitHubService.swift`, modify the `PRBranch` struct (~line 1588):

```swift
struct PRBranch: Codable {
    let ref: String
    let sha: String?
    let repo: PRRepository?  // Can be null for deleted forks
}
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/CIStatusTests test 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add sha field to PRBranch model for CI status support"
```

---

### Task 2: Add `fetchCheckRunStatus()` method

**Files:**
- Modify: `pulse/GitHubService.swift` (add new method near `fetchPRActivity` ~line 688)
- Test: `pulseTests/pulseTests.swift`

**Step 1: Write the failing test**

Add to `CIStatusTests` in `pulseTests/pulseTests.swift`:

```swift
    func testDeriveCheckStatusAllSuccess() {
        // All checks succeeded → "success"
        let runs: [[String: Any]] = [
            ["status": "completed", "conclusion": "success"],
            ["status": "completed", "conclusion": "success"],
        ]
        XCTAssertEqual(GitHubService.deriveCheckStatus(from: runs), "success")
    }

    func testDeriveCheckStatusAnyFailure() {
        let runs: [[String: Any]] = [
            ["status": "completed", "conclusion": "success"],
            ["status": "completed", "conclusion": "failure"],
        ]
        XCTAssertEqual(GitHubService.deriveCheckStatus(from: runs), "failure")
    }

    func testDeriveCheckStatusPending() {
        let runs: [[String: Any]] = [
            ["status": "completed", "conclusion": "success"],
            ["status": "in_progress", "conclusion": NSNull()],
        ]
        XCTAssertEqual(GitHubService.deriveCheckStatus(from: runs), "pending")
    }

    func testDeriveCheckStatusNoRuns() {
        let runs: [[String: Any]] = []
        XCTAssertNil(GitHubService.deriveCheckStatus(from: runs))
    }
```

**Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/CIStatusTests test 2>&1 | tail -20`
Expected: FAIL — `GitHubService` has no member `deriveCheckStatus`

**Step 3: Implement deriveCheckStatus and fetchCheckRunStatus**

Add a static helper and a fetch method to `GitHubService` in `pulse/GitHubService.swift`. Place the static method before `fetchPRActivity` (~line 688):

```swift
    /// Derives overall CI status from an array of check run dictionaries.
    /// Each dict must have "status" (String) and "conclusion" (String or NSNull).
    static func deriveCheckStatus(from checkRuns: [[String: Any]]) -> String? {
        if checkRuns.isEmpty { return nil }

        var hasFailure = false
        var hasPending = false

        for run in checkRuns {
            let status = run["status"] as? String ?? ""
            let conclusion = run["conclusion"] as? String

            if status == "in_progress" || status == "queued" || status == "waiting" || status == "pending" || status == "requested" {
                hasPending = true
            } else if let conclusion = conclusion {
                if conclusion == "failure" || conclusion == "timed_out" || conclusion == "cancelled" {
                    hasFailure = true
                }
            }
        }

        if hasFailure { return "failure" }
        if hasPending { return "pending" }
        return "success"
    }

    /// Fetches CI check run status for a commit SHA.
    private func fetchCheckRunStatus(owner: String, repo: String, sha: String) async -> String? {
        guard let token = personalAccessToken else { return nil }

        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(sha)/check-runs?per_page=100")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let checkRuns = json["check_runs"] as? [[String: Any]] else {
                return nil
            }
            return GitHubService.deriveCheckStatus(from: checkRuns)
        } catch {
            print("[Pulse] Check runs fetch error (\(owner)/\(repo)@\(sha)): \(error.localizedDescription)")
            return nil
        }
    }
```

**Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/CIStatusTests test 2>&1 | tail -20`
Expected: PASS

**Step 5: Commit**

```bash
git add pulse/GitHubService.swift pulseTests/pulseTests.swift
git commit -m "feat: add fetchCheckRunStatus and deriveCheckStatus for CI status"
```

---

### Task 3: Wire check status into fetchPRActivity

**Files:**
- Modify: `pulse/GitHubService.swift:700-707` (fetchPRActivity)

**Step 1: Replace placeholder with real check status fetch**

In `pulse/GitHubService.swift`, find the placeholder in `fetchPRActivity` (~line 704):

Replace:
```swift
        // For now, we don't have easy access to conflicts or check status from search results
        // These would require additional API calls - leave as placeholders
        let hasConflicts = false
        let checkStatus: String? = nil
```

With:
```swift
        let hasConflicts = false
        let checkStatus: String?
        if let sha = pr.head.sha {
            checkStatus = await fetchCheckRunStatus(owner: owner, repo: repo, sha: sha)
        } else {
            checkStatus = nil
        }
```

**Step 2: Fix detectActivityChanges for nil→value transitions**

The current `detectActivityChanges` (~line 819) requires both previous and current `checkStatus` to be non-nil. This means a transition from `nil` (first poll) to `"failure"` won't trigger. That's fine for initial load, but we should also handle the case where `previous.checkStatus` is `"pending"` and current becomes `"failure"`.

The existing code already handles this correctly:
```swift
if currentCheck == "failure" && previousCheck != "failure" {
```

This covers `pending` → `failure` and `success` → `failure`. The only gap is `nil` → `"failure"` on first poll, which we deliberately skip (no spam on app start). No changes needed.

**Step 3: Build and run full tests**

Run: `xcodebuild -scheme pulse -destination 'platform=macOS' test 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|failed"`
Expected: TEST SUCCEEDED

**Step 4: Commit**

```bash
git add pulse/GitHubService.swift
git commit -m "feat: wire CI check status into My PRs activity polling"
```

---

### Task 4: Manual verification

**Step 1: Run the app**

```bash
./run.sh --debug
```

**Step 2: Verify in the app**

1. Open Pulse from the menu bar
2. Go to the My PRs tab
3. Check console output for `[Pulse] Check runs fetch` messages (errors would appear here)
4. If you have a PR with CI, verify that no spurious notifications fire on first load
5. The existing "CI Failures" and "CI Success" toggles in Settings should now function

**Step 3: Commit the design doc**

```bash
git add docs/plans/2026-02-25-ci-status-notifications.md
git commit -m "docs: add CI status notifications implementation plan"
```
