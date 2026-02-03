//
//  pulseTests.swift
//  pulseTests
//
//  Created by Przemyslaw Lusar on 29/01/2026.
//

import XCTest
@testable import pulse

// MARK: - GitHub Service Tests

final class GitHubServiceTests: XCTestCase {
    
    func testInitialState() {
        let service = GitHubService()
        
        // On init, PR arrays should always be empty
        // (isAuthenticated might be true if token exists in keychain)
        XCTAssertTrue(service.awaitingReviewPRs.isEmpty)
        XCTAssertTrue(service.involvedPRs.isEmpty)
        
        // hasLoadedOnce should be false initially
        XCTAssertFalse(service.hasLoadedOnce)
    }
    
    func testPollingDefaults() {
        // Clear UserDefaults to test actual defaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "isPollingEnabled")
        defaults.removeObject(forKey: "pollingInterval")

        let service = GitHubService()

        XCTAssertTrue(service.isPollingEnabled)
        XCTAssertEqual(service.pollingInterval, 300) // 5 minutes
    }

    func testRepositoryMonitoringDefaults() {
        // Clear UserDefaults to test actual defaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "monitorAllRepositories")
        defaults.removeObject(forKey: "monitoredRepositories")

        let service = GitHubService()

        XCTAssertTrue(service.monitorAllRepositories)
        XCTAssertTrue(service.monitoredRepositories.isEmpty)
    }
    
    func testSignOut() {
        let service = GitHubService()
        
        // Simulate authenticated state
        service.personalAccessToken = "test_token"
        service.currentUser = GitHubUser(
            login: "testuser",
            id: 123,
            avatarURL: "https://example.com/avatar.jpg",
            name: "Test User"
        )
        service.awaitingReviewPRs = [createMockPR(id: 1)]
        service.involvedPRs = [createMockPR(id: 2)]
        
        // Sign out
        service.signOut()
        
        // Verify everything is cleared
        XCTAssertNil(service.personalAccessToken)
        XCTAssertNil(service.currentUser)
        XCTAssertTrue(service.awaitingReviewPRs.isEmpty)
        XCTAssertTrue(service.involvedPRs.isEmpty)
    }
}

// MARK: - GitHub Models Tests

final class GitHubModelsTests: XCTestCase {
    
    func testGitHubUserDecoding() throws {
        let json = """
        {
            "login": "octocat",
            "id": 1,
            "avatar_url": "https://github.com/images/error/octocat_happy.gif",
            "name": "The Octocat"
        }
        """
        
        let data = json.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.id, 1)
        XCTAssertEqual(user.avatarURL, "https://github.com/images/error/octocat_happy.gif")
        XCTAssertEqual(user.name, "The Octocat")
    }
    
    func testGitHubUserWithoutName() throws {
        let json = """
        {
            "login": "octocat",
            "id": 1,
            "avatar_url": "https://github.com/images/error/octocat_happy.gif"
        }
        """
        
        let data = json.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: data)
        
        XCTAssertEqual(user.login, "octocat")
        XCTAssertNil(user.name)
    }
    
    func testGitHubIssueRepositoryExtraction() {
        let issue = GitHubIssue(
            number: 123,
            title: "Test PR",
            repositoryURL: "https://api.github.com/repos/octocat/Hello-World"
        )
        
        XCTAssertEqual(issue.repositoryOwner, "octocat")
        XCTAssertEqual(issue.repositoryName, "Hello-World")
    }
    
    func testPullRequestDateParsing() {
        let pr = createMockPR(
            id: 1,
            createdAt: "2024-01-29T10:00:00Z",
            updatedAt: "2024-01-29T15:30:00Z"
        )
        
        // Just verify dates parse correctly without checking exact hours
        // (to avoid timezone issues in tests)
        XCTAssertNotNil(pr.createdDate)
        XCTAssertNotNil(pr.updatedDate)
        XCTAssertTrue(pr.updatedDate > pr.createdDate)
        
        // Verify year/month/day work correctly in UTC
        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(in: timeZone, from: pr.createdDate)
        
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 29)
    }
    
    func testPullRequestRepositoryName() {
        let pr = createMockPR(id: 1)
        
        XCTAssertEqual(pr.repository, "octocat/Hello-World")
    }
}

// MARK: - Keychain Helper Tests

final class KeychainHelperTests: XCTestCase {
    
    func testKeychainSaveAndLoad() {
        let key = "test_key_\(UUID().uuidString)"
        let value = "test_value_123"
        
        KeychainHelper.save(key: key, value: value)
        let loadedValue = KeychainHelper.load(key: key)
        
        XCTAssertEqual(loadedValue, value)
        
        KeychainHelper.delete(key: key)
    }
    
    func testKeychainLoadNonExistent() {
        let key = "non_existent_key_\(UUID().uuidString)"
        let value = KeychainHelper.load(key: key)
        
        XCTAssertNil(value)
    }
    
    func testKeychainDelete() {
        let key = "test_delete_key_\(UUID().uuidString)"
        let value = "test_value"
        
        KeychainHelper.save(key: key, value: value)
        var loadedValue = KeychainHelper.load(key: key)
        XCTAssertEqual(loadedValue, value)
        
        KeychainHelper.delete(key: key)
        loadedValue = KeychainHelper.load(key: key)
        XCTAssertNil(loadedValue)
    }
}

// MARK: - PR Filtering Tests

final class PRFilteringTests: XCTestCase {
    
    func testPRSorting() {
        let pr1 = createMockPR(id: 1, updatedAt: "2024-01-29T10:00:00Z")
        let pr2 = createMockPR(id: 2, updatedAt: "2024-01-29T15:00:00Z")
        let pr3 = createMockPR(id: 3, updatedAt: "2024-01-29T12:00:00Z")
        
        let unsorted = [pr1, pr2, pr3]
        let sorted = unsorted.sorted { $0.updatedDate > $1.updatedDate }
        
        XCTAssertEqual(sorted[0].id, 2)
        XCTAssertEqual(sorted[1].id, 3)
        XCTAssertEqual(sorted[2].id, 1)
    }
    
    func testDraftPRIdentification() {
        let draftPR = createMockPR(id: 1, draft: true)
        let normalPR = createMockPR(id: 2, draft: false)
        
        XCTAssertTrue(draftPR.draft)
        XCTAssertFalse(normalPR.draft)
    }
}

// MARK: - Authentication Flow Tests

final class AuthenticationFlowTests: XCTestCase {

    func testTokenAuthentication() {
        let service = GitHubService()

        // Initially not authenticated
        XCTAssertFalse(service.isAuthenticated)

        // Setting token alone doesn't authenticate - that requires fetchCurrentUser()
        // But we can verify the token is stored
        service.personalAccessToken = "test_token_123"
        XCTAssertEqual(service.personalAccessToken, "test_token_123")

        // isAuthenticated is only set after successful API validation
        // So without mocking the API, it remains false
        XCTAssertFalse(service.isAuthenticated)
    }

    func testSignOutClearsAuth() {
        let service = GitHubService()

        // Simulate a fully authenticated state by setting all required properties
        service.personalAccessToken = "test_token"
        service.isAuthenticated = true  // Directly set to simulate successful auth
        service.currentUser = GitHubUser(
            login: "testuser",
            id: 123,
            avatarURL: "https://example.com/avatar.jpg",
            name: "Test User"
        )

        XCTAssertTrue(service.isAuthenticated)

        service.signOut()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.personalAccessToken)
        XCTAssertNil(service.currentUser)
    }
}
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

// MARK: - Test Helpers

func createMockPR(
    id: Int,
    number: Int = 123,
    title: String = "Test PR",
    createdAt: String = "2024-01-29T10:00:00Z",
    updatedAt: String = "2024-01-29T10:00:00Z",
    draft: Bool = false,
    additions: Int = 10,
    deletions: Int = 5
) -> PullRequest {
    return PullRequest(
        id: id,
        number: number,
        title: title,
        body: "Test body",
        htmlURL: "https://github.com/octocat/Hello-World/pull/\(number)",
        state: "open",
        createdAt: createdAt,
        updatedAt: updatedAt,
        user: PRUser(login: "testuser", avatarURL: "https://example.com/avatar.jpg"),
        draft: draft,
        head: PRBranch(
            ref: "feature-branch",
            repo: PRRepository(name: "Hello-World", fullName: "octocat/Hello-World")
        ),
        base: PRBranch(
            ref: "main",
            repo: PRRepository(name: "Hello-World", fullName: "octocat/Hello-World")
        ),
        additions: additions,
        deletions: deletions,
        changedFiles: 3
    )
}


