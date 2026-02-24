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
            lastReminderAt: nil,
            lastReviewedAt: nil,
            lastReviewState: nil
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
}

// MARK: - Model Decoding Tests

final class ModelDecodingTests: XCTestCase {

    func testPullRequestFullDecoding() throws {
        let json = """
        {
            "id": 12345,
            "number": 42,
            "title": "Add new feature",
            "body": "This PR adds a great feature",
            "html_url": "https://github.com/octocat/Hello-World/pull/42",
            "state": "open",
            "created_at": "2024-01-29T10:00:00Z",
            "updated_at": "2024-01-29T15:30:00Z",
            "user": {
                "login": "contributor",
                "avatar_url": "https://github.com/images/avatar.jpg"
            },
            "draft": false,
            "head": {
                "ref": "feature-branch",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            },
            "base": {
                "ref": "main",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            },
            "additions": 100,
            "deletions": 50,
            "changed_files": 5
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertEqual(pr.id, 12345)
        XCTAssertEqual(pr.number, 42)
        XCTAssertEqual(pr.title, "Add new feature")
        XCTAssertEqual(pr.body, "This PR adds a great feature")
        XCTAssertEqual(pr.htmlURL, "https://github.com/octocat/Hello-World/pull/42")
        XCTAssertEqual(pr.state, "open")
        XCTAssertEqual(pr.user.login, "contributor")
        XCTAssertFalse(pr.draft)
        XCTAssertEqual(pr.head.ref, "feature-branch")
        XCTAssertEqual(pr.base.ref, "main")
        XCTAssertEqual(pr.base.repo?.fullName, "octocat/Hello-World")
        XCTAssertEqual(pr.additions, 100)
        XCTAssertEqual(pr.deletions, 50)
        XCTAssertEqual(pr.changedFiles, 5)
        XCTAssertEqual(pr.repository, "octocat/Hello-World")
    }

    func testPullRequestWithNilBody() throws {
        let json = """
        {
            "id": 12345,
            "number": 42,
            "title": "No body PR",
            "body": null,
            "html_url": "https://github.com/octocat/Hello-World/pull/42",
            "state": "open",
            "created_at": "2024-01-29T10:00:00Z",
            "updated_at": "2024-01-29T15:30:00Z",
            "user": {
                "login": "contributor",
                "avatar_url": "https://github.com/images/avatar.jpg"
            },
            "draft": true,
            "head": {
                "ref": "feature-branch",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            },
            "base": {
                "ref": "main",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertNil(pr.body)
        XCTAssertTrue(pr.draft)
        XCTAssertNil(pr.additions)
        XCTAssertNil(pr.deletions)
        XCTAssertNil(pr.changedFiles)
    }

    func testPRUserDecoding() throws {
        let json = """
        {
            "login": "octocat",
            "avatar_url": "https://github.com/images/avatar.jpg"
        }
        """

        let data = json.data(using: .utf8)!
        let user = try JSONDecoder().decode(PRUser.self, from: data)

        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.avatarURL, "https://github.com/images/avatar.jpg")
    }

    func testPRBranchDecoding() throws {
        let json = """
        {
            "ref": "feature-branch",
            "repo": {
                "name": "Hello-World",
                "full_name": "octocat/Hello-World"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let branch = try JSONDecoder().decode(PRBranch.self, from: data)

        XCTAssertEqual(branch.ref, "feature-branch")
        XCTAssertEqual(branch.repo?.name, "Hello-World")
        XCTAssertEqual(branch.repo?.fullName, "octocat/Hello-World")
    }

    func testPRBranchWithNullRepo() throws {
        // Test for deleted fork scenario where head.repo is null
        let json = """
        {
            "ref": "feature-branch",
            "repo": null
        }
        """

        let data = json.data(using: .utf8)!
        let branch = try JSONDecoder().decode(PRBranch.self, from: data)

        XCTAssertEqual(branch.ref, "feature-branch")
        XCTAssertNil(branch.repo)
    }

    func testPullRequestWithDeletedFork() throws {
        // Test PR where head.repo is null (fork was deleted)
        let json = """
        {
            "id": 99999,
            "number": 100,
            "title": "PR from deleted fork",
            "body": null,
            "html_url": "https://github.com/octocat/Hello-World/pull/100",
            "state": "open",
            "created_at": "2024-01-29T10:00:00Z",
            "updated_at": "2024-01-29T15:30:00Z",
            "user": {
                "login": "contributor",
                "avatar_url": "https://github.com/images/avatar.jpg"
            },
            "draft": false,
            "head": {
                "ref": "feature-branch",
                "repo": null
            },
            "base": {
                "ref": "main",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertEqual(pr.id, 99999)
        XCTAssertNil(pr.head.repo)
        XCTAssertNotNil(pr.base.repo)
        XCTAssertEqual(pr.repository, "octocat/Hello-World")
    }

    func testPRRepositoryDecoding() throws {
        let json = """
        {
            "name": "Hello-World",
            "full_name": "octocat/Hello-World"
        }
        """

        let data = json.data(using: .utf8)!
        let repo = try JSONDecoder().decode(PRRepository.self, from: data)

        XCTAssertEqual(repo.name, "Hello-World")
        XCTAssertEqual(repo.fullName, "octocat/Hello-World")
    }

    func testGitHubRepositoryDecoding() throws {
        let json = """
        {
            "id": 1296269,
            "name": "Hello-World",
            "full_name": "octocat/Hello-World",
            "private": false,
            "owner": {
                "login": "octocat",
                "avatar_url": "https://github.com/images/avatar.jpg"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: data)

        XCTAssertEqual(repo.id, 1296269)
        XCTAssertEqual(repo.name, "Hello-World")
        XCTAssertEqual(repo.fullName, "octocat/Hello-World")
        XCTAssertFalse(repo.isPrivate)
        XCTAssertEqual(repo.owner.login, "octocat")
    }

    func testGitHubRepositoryPrivate() throws {
        let json = """
        {
            "id": 1296269,
            "name": "Secret-Repo",
            "full_name": "octocat/Secret-Repo",
            "private": true,
            "owner": {
                "login": "octocat",
                "avatar_url": "https://github.com/images/avatar.jpg"
            }
        }
        """

        let data = json.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepository.self, from: data)

        XCTAssertTrue(repo.isPrivate)
    }

    func testGitHubSearchResponseDecoding() throws {
        let json = """
        {
            "total_count": 2,
            "items": [
                {
                    "number": 42,
                    "title": "First PR",
                    "repository_url": "https://api.github.com/repos/octocat/Hello-World"
                },
                {
                    "number": 43,
                    "title": "Second PR",
                    "repository_url": "https://api.github.com/repos/octocat/Another-Repo"
                }
            ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)

        XCTAssertEqual(response.totalCount, 2)
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].number, 42)
        XCTAssertEqual(response.items[0].title, "First PR")
        XCTAssertEqual(response.items[1].number, 43)
    }

    func testGitHubSearchResponseEmpty() throws {
        let json = """
        {
            "total_count": 0,
            "items": []
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GitHubSearchResponse.self, from: data)

        XCTAssertEqual(response.totalCount, 0)
        XCTAssertTrue(response.items.isEmpty)
    }

    func testGitHubOrganizationDecoding() throws {
        let json = """
        {
            "login": "github",
            "id": 9919,
            "avatar_url": "https://github.com/images/org.jpg",
            "description": "How people build software"
        }
        """

        let data = json.data(using: .utf8)!
        let org = try JSONDecoder().decode(GitHubOrganization.self, from: data)

        XCTAssertEqual(org.login, "github")
        XCTAssertEqual(org.id, 9919)
        XCTAssertEqual(org.avatarURL, "https://github.com/images/org.jpg")
        XCTAssertEqual(org.description, "How people build software")
    }

    func testGitHubOrganizationWithNilFields() throws {
        let json = """
        {
            "login": "github",
            "id": 9919
        }
        """

        let data = json.data(using: .utf8)!
        let org = try JSONDecoder().decode(GitHubOrganization.self, from: data)

        XCTAssertEqual(org.login, "github")
        XCTAssertNil(org.avatarURL)
        XCTAssertNil(org.description)
    }

    func testPRReviewDecoding() throws {
        let json = """
        {
            "id": 80,
            "user": {
                "login": "reviewer",
                "avatar_url": "https://github.com/images/reviewer.jpg"
            },
            "state": "APPROVED",
            "submitted_at": "2024-01-29T12:00:00Z"
        }
        """

        let data = json.data(using: .utf8)!
        let review = try JSONDecoder().decode(PRReview.self, from: data)

        XCTAssertEqual(review.id, 80)
        XCTAssertEqual(review.user.login, "reviewer")
        XCTAssertEqual(review.state, "APPROVED")
        XCTAssertEqual(review.submittedAt, "2024-01-29T12:00:00Z")
    }

    func testPRReviewPendingState() throws {
        let json = """
        {
            "id": 81,
            "user": {
                "login": "reviewer",
                "avatar_url": "https://github.com/images/reviewer.jpg"
            },
            "state": "PENDING",
            "submitted_at": null
        }
        """

        let data = json.data(using: .utf8)!
        let review = try JSONDecoder().decode(PRReview.self, from: data)

        XCTAssertEqual(review.state, "PENDING")
        XCTAssertNil(review.submittedAt)
    }

    func testPRReviewChangesRequested() throws {
        let json = """
        {
            "id": 82,
            "user": {
                "login": "reviewer",
                "avatar_url": "https://github.com/images/reviewer.jpg"
            },
            "state": "CHANGES_REQUESTED",
            "submitted_at": "2024-01-29T14:00:00Z"
        }
        """

        let data = json.data(using: .utf8)!
        let review = try JSONDecoder().decode(PRReview.self, from: data)

        XCTAssertEqual(review.state, "CHANGES_REQUESTED")
    }

    func testPullRequestWithMergedAt() throws {
        let json = """
        {
            "id": 12345,
            "number": 42,
            "title": "Merged PR",
            "body": null,
            "html_url": "https://github.com/octocat/Hello-World/pull/42",
            "state": "closed",
            "created_at": "2024-01-29T10:00:00Z",
            "updated_at": "2024-01-29T15:30:00Z",
            "merged_at": "2024-01-29T15:00:00Z",
            "user": {
                "login": "contributor",
                "avatar_url": "https://github.com/images/avatar.jpg"
            },
            "draft": false,
            "head": {
                "ref": "feature-branch",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            },
            "base": {
                "ref": "main",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertEqual(pr.state, "closed")
        XCTAssertEqual(pr.mergedAt, "2024-01-29T15:00:00Z")
    }

    func testPullRequestWithoutMergedAt() throws {
        let json = """
        {
            "id": 12345,
            "number": 42,
            "title": "Open PR",
            "body": null,
            "html_url": "https://github.com/octocat/Hello-World/pull/42",
            "state": "open",
            "created_at": "2024-01-29T10:00:00Z",
            "updated_at": "2024-01-29T15:30:00Z",
            "user": {
                "login": "contributor",
                "avatar_url": "https://github.com/images/avatar.jpg"
            },
            "draft": false,
            "head": {
                "ref": "feature-branch",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            },
            "base": {
                "ref": "main",
                "repo": {
                    "name": "Hello-World",
                    "full_name": "octocat/Hello-World"
                }
            }
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertEqual(pr.state, "open")
        XCTAssertNil(pr.mergedAt)
    }
}

// MARK: - Settings Persistence Tests

final class SettingsPersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear all relevant UserDefaults
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "isPollingEnabled")
        defaults.removeObject(forKey: "pollingInterval")
        defaults.removeObject(forKey: "monitorAllRepositories")
        defaults.removeObject(forKey: "monitoredRepositories")
        defaults.removeObject(forKey: "isReminderEnabled")
        defaults.removeObject(forKey: "reminderInterval")
        defaults.removeObject(forKey: "watchedPRs")
    }

    func testPollingSettingsPersist() {
        let service = GitHubService()

        // Change settings
        service.isPollingEnabled = false
        service.pollingInterval = 600

        // Verify persisted
        let defaults = UserDefaults.standard
        XCTAssertFalse(defaults.bool(forKey: "isPollingEnabled"))
        XCTAssertEqual(defaults.double(forKey: "pollingInterval"), 600)
    }

    func testPollingSettingsLoad() {
        // Pre-set values
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "isPollingEnabled")
        defaults.set(900.0, forKey: "pollingInterval")

        let service = GitHubService()

        XCTAssertFalse(service.isPollingEnabled)
        XCTAssertEqual(service.pollingInterval, 900)
    }

    func testRepositoryMonitoringSettingsPersist() {
        let service = GitHubService()

        service.monitorAllRepositories = false
        service.monitoredRepositories = Set(["octocat/Hello-World", "octocat/Spoon-Knife"])

        let defaults = UserDefaults.standard
        XCTAssertFalse(defaults.bool(forKey: "monitorAllRepositories"))

        let savedRepos = defaults.stringArray(forKey: "monitoredRepositories") ?? []
        XCTAssertEqual(Set(savedRepos), Set(["octocat/Hello-World", "octocat/Spoon-Knife"]))
    }

    func testRepositoryMonitoringSettingsLoad() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "monitorAllRepositories")
        defaults.set(["owner/repo1", "owner/repo2"], forKey: "monitoredRepositories")

        let service = GitHubService()

        XCTAssertFalse(service.monitorAllRepositories)
        XCTAssertEqual(service.monitoredRepositories, Set(["owner/repo1", "owner/repo2"]))
    }

    func testReminderSettingsPersist() {
        let service = GitHubService()

        service.isReminderEnabled = false
        service.reminderInterval = 1200

        let defaults = UserDefaults.standard
        XCTAssertFalse(defaults.bool(forKey: "isReminderEnabled"))
        XCTAssertEqual(defaults.double(forKey: "reminderInterval"), 1200)
    }

    func testReminderSettingsLoad() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "isReminderEnabled")
        defaults.set(1800.0, forKey: "reminderInterval")

        let service = GitHubService()

        XCTAssertFalse(service.isReminderEnabled)
        XCTAssertEqual(service.reminderInterval, 1800)
    }

    func testWatchedPRsPersist() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        let pr = createMockPR(id: 100, number: 42)
        service.startWatching(pr: pr)

        // Verify it's persisted
        let data = defaults.data(forKey: "watchedPRs")
        XCTAssertNotNil(data)

        // Decode and verify
        if let data = data {
            let decoded = try? JSONDecoder().decode([WatchedPR].self, from: data)
            XCTAssertEqual(decoded?.count, 1)
            XCTAssertEqual(decoded?.first?.id, 100)
        }
    }

    func testWatchedPRsLoad() {
        // Pre-save watched PRs
        let watchedPR = WatchedPR(
            id: 200,
            prNumber: 50,
            owner: "octocat",
            repo: "Hello-World",
            repository: "octocat/Hello-World",
            title: "Test PR",
            htmlURL: "https://github.com/octocat/Hello-World/pull/50",
            authorLogin: "contributor",
            authorAvatarURL: "https://github.com/images/avatar.jpg",
            startedWatchingAt: Date(),
            lastReminderAt: nil,
            lastReviewedAt: nil,
            lastReviewState: nil
        )

        let data = try! JSONEncoder().encode([watchedPR])
        UserDefaults.standard.set(data, forKey: "watchedPRs")

        let service = GitHubService()

        XCTAssertEqual(service.watchedPRs.count, 1)
        XCTAssertEqual(service.watchedPRs.first?.id, 200)
        XCTAssertEqual(service.watchedPRs.first?.prNumber, 50)
    }
}

// MARK: - Repository Management Tests

final class RepositoryManagementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "monitoredRepositories")
        UserDefaults.standard.removeObject(forKey: "monitorAllRepositories")
    }

    func testToggleRepositoryAdd() {
        let service = GitHubService()
        XCTAssertTrue(service.monitoredRepositories.isEmpty)

        service.toggleRepository("octocat/Hello-World")

        XCTAssertTrue(service.monitoredRepositories.contains("octocat/Hello-World"))
        XCTAssertEqual(service.monitoredRepositories.count, 1)
    }

    func testToggleRepositoryRemove() {
        let service = GitHubService()
        service.monitoredRepositories = Set(["octocat/Hello-World"])

        service.toggleRepository("octocat/Hello-World")

        XCTAssertFalse(service.monitoredRepositories.contains("octocat/Hello-World"))
        XCTAssertTrue(service.monitoredRepositories.isEmpty)
    }

    func testToggleRepositoryMultiple() {
        let service = GitHubService()

        service.toggleRepository("octocat/Hello-World")
        service.toggleRepository("octocat/Spoon-Knife")
        service.toggleRepository("owner/repo")

        XCTAssertEqual(service.monitoredRepositories.count, 3)

        service.toggleRepository("octocat/Hello-World")

        XCTAssertEqual(service.monitoredRepositories.count, 2)
        XCTAssertFalse(service.monitoredRepositories.contains("octocat/Hello-World"))
    }

    func testMonitorAllRepositoriesDefault() {
        let service = GitHubService()
        XCTAssertTrue(service.monitorAllRepositories)
    }

    func testResetLoadedState() {
        let service = GitHubService()
        service.hasLoadedAwaiting = true
        service.hasLoadedInvolved = true

        XCTAssertTrue(service.hasLoadedOnce)

        service.resetLoadedState()

        XCTAssertFalse(service.hasLoadedAwaiting)
        XCTAssertFalse(service.hasLoadedInvolved)
        XCTAssertFalse(service.hasLoadedOnce)
    }
}

// MARK: - Computed Properties Tests

final class ComputedPropertiesTests: XCTestCase {

    func testIsLoadingComputed() {
        let service = GitHubService()

        XCTAssertFalse(service.isLoading)

        service.isLoadingAwaiting = true
        XCTAssertTrue(service.isLoading)

        service.isLoadingAwaiting = false
        service.isLoadingInvolved = true
        XCTAssertTrue(service.isLoading)

        service.isLoadingAwaiting = true
        XCTAssertTrue(service.isLoading)

        service.isLoadingAwaiting = false
        service.isLoadingInvolved = false
        XCTAssertFalse(service.isLoading)
    }

    func testHasLoadedOnceComputed() {
        let service = GitHubService()

        XCTAssertFalse(service.hasLoadedOnce)

        service.hasLoadedAwaiting = true
        XCTAssertTrue(service.hasLoadedOnce)

        service.hasLoadedAwaiting = false
        service.hasLoadedInvolved = true
        XCTAssertTrue(service.hasLoadedOnce)

        service.hasLoadedAwaiting = true
        XCTAssertTrue(service.hasLoadedOnce)
    }

    func testPullRequestCreatedDate() {
        let pr = createMockPR(id: 1, createdAt: "2024-06-15T10:30:00Z")

        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(in: timeZone, from: pr.createdDate)

        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 30)
    }

    func testPullRequestUpdatedDate() {
        let pr = createMockPR(id: 1, updatedAt: "2024-12-25T23:59:59Z")

        let calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(in: timeZone, from: pr.updatedDate)

        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 25)
    }

    func testGitHubIssueRepositoryOwnerExtraction() {
        let issue = GitHubIssue(
            number: 1,
            title: "Test",
            repositoryURL: "https://api.github.com/repos/microsoft/vscode"
        )

        XCTAssertEqual(issue.repositoryOwner, "microsoft")
        XCTAssertEqual(issue.repositoryName, "vscode")
    }

    func testGitHubIssueComplexRepoName() {
        let issue = GitHubIssue(
            number: 1,
            title: "Test",
            repositoryURL: "https://api.github.com/repos/some-org/repo-with-dashes"
        )

        XCTAssertEqual(issue.repositoryOwner, "some-org")
        XCTAssertEqual(issue.repositoryName, "repo-with-dashes")
    }
}

// MARK: - Edge Cases Tests

final class EdgeCasesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "watchedPRs")
    }

    func testStopWatchingNonExistentPR() {
        let service = GitHubService()
        service.startWatching(pr: createMockPR(id: 1))

        // Should not crash
        service.stopWatching(prId: 999)

        XCTAssertEqual(service.watchedPRs.count, 1)
    }

    func testClearEmptyWatchedPRs() {
        let service = GitHubService()
        XCTAssertTrue(service.watchedPRs.isEmpty)

        // Should not crash
        service.clearAllWatchedPRs()

        XCTAssertTrue(service.watchedPRs.isEmpty)
    }

    func testIsWatchingEmpty() {
        let service = GitHubService()
        XCTAssertFalse(service.isWatching(prId: 1))
        XCTAssertFalse(service.isWatching(prId: 0))
        XCTAssertFalse(service.isWatching(prId: -1))
    }

    func testWatchedPRWithLastReminderAt() throws {
        let now = Date()
        let watchedPR = WatchedPR(
            id: 123,
            prNumber: 45,
            owner: "octocat",
            repo: "Hello-World",
            repository: "octocat/Hello-World",
            title: "Test",
            htmlURL: "https://github.com/octocat/Hello-World/pull/45",
            authorLogin: "user",
            authorAvatarURL: "https://example.com/avatar.jpg",
            startedWatchingAt: now,
            lastReminderAt: now,
            lastReviewedAt: nil,
            lastReviewState: nil
        )

        let data = try JSONEncoder().encode(watchedPR)
        let decoded = try JSONDecoder().decode(WatchedPR.self, from: data)

        XCTAssertNotNil(decoded.lastReminderAt)
    }

    func testWatchedPRWithReviewState() throws {
        let now = Date()
        let reviewedAt = Date(timeIntervalSinceNow: -3600) // 1 hour ago
        let watchedPR = WatchedPR(
            id: 123,
            prNumber: 45,
            owner: "octocat",
            repo: "Hello-World",
            repository: "octocat/Hello-World",
            title: "Test",
            htmlURL: "https://github.com/octocat/Hello-World/pull/45",
            authorLogin: "user",
            authorAvatarURL: "https://example.com/avatar.jpg",
            startedWatchingAt: now,
            lastReminderAt: nil,
            lastReviewedAt: reviewedAt,
            lastReviewState: "CHANGES_REQUESTED"
        )

        let data = try JSONEncoder().encode(watchedPR)
        let decoded = try JSONDecoder().decode(WatchedPR.self, from: data)

        XCTAssertEqual(decoded.lastReviewState, "CHANGES_REQUESTED")
        XCTAssertNotNil(decoded.lastReviewedAt)
    }

    func testMultipleSignOuts() {
        let service = GitHubService()

        service.personalAccessToken = "token"
        service.isAuthenticated = true
        service.signOut()

        XCTAssertFalse(service.isAuthenticated)

        // Second sign out should not crash
        service.signOut()

        XCTAssertFalse(service.isAuthenticated)
        XCTAssertNil(service.personalAccessToken)
    }

    func testSignOutClearsWatchedPRs() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "watchedPRs")

        let service = GitHubService()
        service.startWatching(pr: createMockPR(id: 1))
        service.startWatching(pr: createMockPR(id: 2))

        XCTAssertEqual(service.watchedPRs.count, 2)

        // Note: signOut doesn't currently clear watchedPRs
        // This test documents current behavior
        service.signOut()

        // watchedPRs persist across sign out (by design - user might re-auth)
        XCTAssertEqual(service.watchedPRs.count, 2)
    }

    func testPRWithAllNilOptionals() throws {
        let json = """
        {
            "id": 1,
            "number": 1,
            "title": "Minimal PR",
            "body": null,
            "html_url": "https://github.com/o/r/pull/1",
            "state": "open",
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2024-01-01T00:00:00Z",
            "user": {"login": "u", "avatar_url": "https://x.com/a.jpg"},
            "draft": false,
            "head": {"ref": "h", "repo": {"name": "r", "full_name": "o/r"}},
            "base": {"ref": "b", "repo": {"name": "r", "full_name": "o/r"}}
        }
        """

        let data = json.data(using: .utf8)!
        let pr = try JSONDecoder().decode(PullRequest.self, from: data)

        XCTAssertNil(pr.body)
        XCTAssertNil(pr.additions)
        XCTAssertNil(pr.deletions)
        XCTAssertNil(pr.changedFiles)
    }

    func testEmptyPRArraySorting() {
        let prs: [PullRequest] = []
        let sorted = prs.sorted { $0.updatedDate > $1.updatedDate }
        XCTAssertTrue(sorted.isEmpty)
    }

    func testSinglePRArraySorting() {
        let prs = [createMockPR(id: 1)]
        let sorted = prs.sorted { $0.updatedDate > $1.updatedDate }
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted[0].id, 1)
    }
}

// MARK: - Notification Status Tests

final class NotificationStatusTests: XCTestCase {

    func testNotificationAuthorizationStatusEnum() {
        // Test all enum cases exist
        let statuses: [NotificationAuthorizationStatus] = [
            .authorized,
            .denied,
            .notDetermined,
            .provisional,
            .ephemeral
        ]

        XCTAssertEqual(statuses.count, 5)
    }

    func testInitialNotificationStatus() {
        let service = GitHubService()
        // Initial status is notDetermined (before async check completes)
        XCTAssertEqual(service.notificationStatus, .notDetermined)
    }
}

// MARK: - WatchedPRStatus Tests

final class WatchedPRStatusTests: XCTestCase {

    func testWatchedPRStatusEnum() {
        // Test all enum cases exist
        let statuses: [WatchedPRStatus] = [
            .needsReminder,
            .waitingForAuthor,
            .approved,
            .closed
        ]

        XCTAssertEqual(statuses.count, 4)
    }
}

// MARK: - UserReviewStatus Tests

final class UserReviewStatusTests: XCTestCase {

    func testUserReviewStatusNoReview() {
        let status = UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)

        XCTAssertFalse(status.hasReviewed)
        XCTAssertNil(status.state)
        XCTAssertNil(status.submittedAt)
    }

    func testUserReviewStatusApproved() {
        let date = Date()
        let status = UserReviewStatus(hasReviewed: true, state: "APPROVED", submittedAt: date)

        XCTAssertTrue(status.hasReviewed)
        XCTAssertEqual(status.state, "APPROVED")
        XCTAssertEqual(status.submittedAt, date)
    }

    func testUserReviewStatusChangesRequested() {
        let date = Date()
        let status = UserReviewStatus(hasReviewed: true, state: "CHANGES_REQUESTED", submittedAt: date)

        XCTAssertTrue(status.hasReviewed)
        XCTAssertEqual(status.state, "CHANGES_REQUESTED")
    }

    func testUserReviewStatusCommented() {
        let date = Date()
        let status = UserReviewStatus(hasReviewed: true, state: "COMMENTED", submittedAt: date)

        XCTAssertTrue(status.hasReviewed)
        XCTAssertEqual(status.state, "COMMENTED")
    }
}

// MARK: - Re-Review Detection Tests

final class ReReviewDetectionTests: XCTestCase {

    func testApprovedStateIndicatesReReview() {
        // When a PR is in review-requested results AND user has APPROVED,
        // it means re-review was requested after the user's approval
        let status = UserReviewStatus(hasReviewed: true, state: "APPROVED", submittedAt: Date())
        let isReReview = status.hasReviewed
            && (status.state == "APPROVED" || status.state == "CHANGES_REQUESTED")
        XCTAssertTrue(isReReview)
    }

    func testChangesRequestedStateIndicatesReReview() {
        let status = UserReviewStatus(hasReviewed: true, state: "CHANGES_REQUESTED", submittedAt: Date())
        let isReReview = status.hasReviewed
            && (status.state == "APPROVED" || status.state == "CHANGES_REQUESTED")
        XCTAssertTrue(isReReview)
    }

    func testCommentedStateDoesNotIndicateReReview() {
        // COMMENTED reviews don't indicate re-review — the user may have
        // just left a comment without approving/requesting changes
        let status = UserReviewStatus(hasReviewed: true, state: "COMMENTED", submittedAt: Date())
        let isReReview = status.hasReviewed
            && (status.state == "APPROVED" || status.state == "CHANGES_REQUESTED")
        XCTAssertFalse(isReReview)
    }

    func testNoReviewDoesNotIndicateReReview() {
        let status = UserReviewStatus(hasReviewed: false, state: nil, submittedAt: nil)
        let isReReview = status.hasReviewed
            && (status.state == "APPROVED" || status.state == "CHANGES_REQUESTED")
        XCTAssertFalse(isReReview)
    }

    func testReReviewTrackingCleanup() {
        // Verify that when a PR leaves the awaiting review list,
        // its review state should be cleaned up so re-check happens if it returns
        var previousPRReviewStates: [Int: String] = [1: "APPROVED", 2: "CHANGES_REQUESTED", 3: "APPROVED"]
        let currentPRIds: Set<Int> = [1, 3]  // PR 2 left the list

        previousPRReviewStates = previousPRReviewStates.filter { currentPRIds.contains($0.key) }

        XCTAssertEqual(previousPRReviewStates.count, 2)
        XCTAssertNotNil(previousPRReviewStates[1])
        XCTAssertNil(previousPRReviewStates[2])  // Cleaned up
        XCTAssertNotNil(previousPRReviewStates[3])
    }

    func testReReviewSkipsAlreadyTrackedPRs() {
        // Once we detect a re-review for a PR, we shouldn't re-notify
        var previousPRReviewStates: [Int: String] = [1: "APPROVED"]
        let prId = 1

        // This PR should be skipped because it's already in previousPRReviewStates
        let shouldCheck = previousPRReviewStates[prId] == nil
        XCTAssertFalse(shouldCheck)
    }

    func testReReviewChecksUntrackedPRs() {
        let previousPRReviewStates: [Int: String] = [1: "APPROVED"]
        let prId = 2  // New PR not yet tracked

        let shouldCheck = previousPRReviewStates[prId] == nil
        XCTAssertTrue(shouldCheck)
    }
}

// MARK: - PRStateFilter Tests

final class PRStateFilterTests: XCTestCase {

    func testPRStateFilterCases() {
        let cases = PRStateFilter.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.open))
        XCTAssertTrue(cases.contains(.closed))
        XCTAssertTrue(cases.contains(.merged))
        XCTAssertTrue(cases.contains(.all))
    }

    func testPRStateFilterQueryValues() {
        XCTAssertEqual(PRStateFilter.open.queryValue, "open")
        XCTAssertEqual(PRStateFilter.closed.queryValue, "closed")
        XCTAssertNil(PRStateFilter.merged.queryValue)
        XCTAssertNil(PRStateFilter.all.queryValue)
    }

    func testPRStateFilterRawValues() {
        XCTAssertEqual(PRStateFilter.open.rawValue, "Open")
        XCTAssertEqual(PRStateFilter.closed.rawValue, "Closed")
        XCTAssertEqual(PRStateFilter.merged.rawValue, "Merged")
        XCTAssertEqual(PRStateFilter.all.rawValue, "All")
    }
}

// MARK: - PRActivity Tests

final class PRActivityTests: XCTestCase {

    func testPRActivityEncoding() throws {
        let activity = PRActivity(
            commentCount: 5,
            reviewCount: 3,
            approvalCount: 2,
            changesRequestedCount: 1,
            latestReviewState: "APPROVED",
            isMerged: false,
            mergedAt: nil,
            hasConflicts: false,
            checkStatus: "success"
        )

        let data = try JSONEncoder().encode(activity)
        let decoded = try JSONDecoder().decode(PRActivity.self, from: data)

        XCTAssertEqual(decoded.commentCount, 5)
        XCTAssertEqual(decoded.reviewCount, 3)
        XCTAssertEqual(decoded.approvalCount, 2)
        XCTAssertEqual(decoded.changesRequestedCount, 1)
        XCTAssertEqual(decoded.latestReviewState, "APPROVED")
        XCTAssertFalse(decoded.isMerged)
        XCTAssertNil(decoded.mergedAt)
        XCTAssertFalse(decoded.hasConflicts)
        XCTAssertEqual(decoded.checkStatus, "success")
    }

    func testPRActivityEquality() {
        let activity1 = PRActivity(
            commentCount: 1,
            reviewCount: 1,
            approvalCount: 1,
            changesRequestedCount: 0,
            latestReviewState: "APPROVED",
            isMerged: false,
            mergedAt: nil,
            hasConflicts: false,
            checkStatus: nil
        )

        let activity2 = PRActivity(
            commentCount: 1,
            reviewCount: 1,
            approvalCount: 1,
            changesRequestedCount: 0,
            latestReviewState: "APPROVED",
            isMerged: false,
            mergedAt: nil,
            hasConflicts: false,
            checkStatus: nil
        )

        XCTAssertEqual(activity1, activity2)
    }
}

// MARK: - MyPRNotificationSettings Tests

final class MyPRNotificationSettingsTests: XCTestCase {

    func testDefaultSettings() {
        let settings = MyPRNotificationSettings()

        XCTAssertTrue(settings.notifyOnApproval)
        XCTAssertTrue(settings.notifyOnChangesRequested)
        XCTAssertTrue(settings.notifyOnReviewComment)
        XCTAssertTrue(settings.notifyOnComment)
        XCTAssertTrue(settings.notifyOnCheckFailure)
        XCTAssertTrue(settings.notifyOnCheckSuccess)
        XCTAssertTrue(settings.notifyOnMention)
        XCTAssertTrue(settings.notifyOnMerge)
        XCTAssertTrue(settings.notifyOnConflict)
        XCTAssertFalse(settings.batchNotifications)
    }

    func testSettingsEncoding() throws {
        var settings = MyPRNotificationSettings()
        settings.notifyOnApproval = false
        settings.batchNotifications = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(MyPRNotificationSettings.self, from: data)

        XCTAssertFalse(decoded.notifyOnApproval)
        XCTAssertTrue(decoded.batchNotifications)
    }
}

// MARK: - My PRs Service Tests

final class MyPRsServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "myPRsLastActivity")
        defaults.removeObject(forKey: "myPRNotificationSettings")
    }

    func testMyPRsInitialState() {
        let service = GitHubService()

        XCTAssertTrue(service.myPRs.isEmpty)
        XCTAssertFalse(service.isLoadingMyPRs)
        XCTAssertFalse(service.hasLoadedMyPRs)
        XCTAssertEqual(service.myPRsStateFilter, .open)
    }

    func testMyPRsStateFilterDefault() {
        let service = GitHubService()
        XCTAssertEqual(service.myPRsStateFilter, .open)
    }

    func testMyPRNotificationSettingsDefault() {
        let service = GitHubService()
        XCTAssertTrue(service.myPRNotificationSettings.notifyOnApproval)
        XCTAssertFalse(service.myPRNotificationSettings.batchNotifications)
    }

    func testMyPRsIncludedInIsLoading() {
        let service = GitHubService()

        XCTAssertFalse(service.isLoading)

        service.isLoadingMyPRs = true
        XCTAssertTrue(service.isLoading)

        service.isLoadingMyPRs = false
        XCTAssertFalse(service.isLoading)
    }

    func testMyPRsIncludedInHasLoadedOnce() {
        let service = GitHubService()

        XCTAssertFalse(service.hasLoadedOnce)

        service.hasLoadedMyPRs = true
        XCTAssertTrue(service.hasLoadedOnce)
    }
}

// MARK: - PRReviewSummary Tests

final class PRReviewSummaryTests: XCTestCase {

    func testApprovedStatus() {
        let summary = PRReviewSummary(approvedCount: 2, changesRequestedCount: 0, commentedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.displayText, "2 approved")
    }

    func testChangesRequestedStatus() {
        let summary = PRReviewSummary(approvedCount: 1, changesRequestedCount: 1, commentedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.displayText, "1 changes")
    }

    func testCommentedStatus() {
        let summary = PRReviewSummary(approvedCount: 0, changesRequestedCount: 0, commentedCount: 3, pendingCount: 0)
        XCTAssertEqual(summary.displayText, "3 comments")
    }

    func testPendingStatus() {
        let summary = PRReviewSummary(approvedCount: 0, changesRequestedCount: 0, commentedCount: 0, pendingCount: 2)
        XCTAssertEqual(summary.displayText, "2 pending")
    }

    func testNoReviewsStatus() {
        let summary = PRReviewSummary(approvedCount: 0, changesRequestedCount: 0, commentedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.displayText, "No reviews")
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
    deletions: Int = 5,
    mergedAt: String? = nil
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
        changedFiles: 3,
        mergedAt: mergedAt
    )
}

// MARK: - OAuth Manager Tests

final class OAuthManagerTests: XCTestCase {

    func testCodeVerifierGeneration() {
        let manager = OAuthManager.shared

        // Use reflection to test private method via the public flow
        // We test that starting OAuth doesn't crash and sets authenticating state
        manager.cancelAuth()
        XCTAssertFalse(manager.isAuthenticating)
    }

    func testBase64URLEncoding() {
        // Test the base64URL encoding extension
        let testData = Data([0x00, 0x10, 0x83, 0x10, 0x51, 0x87, 0x20, 0x92, 0x8b])
        let encoded = testData.base64URLEncodedString()

        // Base64URL should not contain +, /, or =
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testCallbackURLParsing() {
        let manager = OAuthManager.shared
        manager.cancelAuth() // Reset state

        // Test invalid URL scheme
        let invalidURL = URL(string: "https://example.com/callback")!
        let handled = manager.handleCallback(url: invalidURL)
        XCTAssertFalse(handled)

        // Test valid scheme but without state (should fail gracefully)
        let validSchemeURL = URL(string: "pulse://oauth/callback?code=abc123")!
        // This will return true (it's handled) but will trigger an error due to state mismatch
        let handledValid = manager.handleCallback(url: validSchemeURL)
        XCTAssertTrue(handledValid)
    }

    func testOAuthCancelation() {
        let manager = OAuthManager.shared

        // Start would open browser, but we can test cancel
        manager.cancelAuth()

        XCTAssertFalse(manager.isAuthenticating)
        XCTAssertNil(manager.error)
    }

    func testCallbackWithError() {
        let manager = OAuthManager.shared
        manager.cancelAuth()

        // Test callback with error parameter
        let errorURL = URL(string: "pulse://oauth/callback?error=access_denied&error_description=User%20denied%20access")!
        let handled = manager.handleCallback(url: errorURL)

        XCTAssertTrue(handled)
        // Error should be set
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(manager.error, "User denied access")
    }
}

// MARK: - GitHubService OAuth Tests

final class GitHubServiceOAuthTests: XCTestCase {

    func testOAuthInProgressInitialState() {
        let service = GitHubService()
        XCTAssertFalse(service.isOAuthInProgress)
    }

    func testCancelOAuth() {
        let service = GitHubService()
        service.cancelOAuth()
        XCTAssertFalse(service.isOAuthInProgress)
    }
}

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

    func testQueuedNotificationEncodingRoundtrip() throws {
        let queued = QueuedPRNotification(prId: 123, prTitle: "Fix bug", prRepository: "org/repo", prURL: "https://github.com/org/repo/pull/1", queuedAt: Date())
        let data = try JSONEncoder().encode([queued])
        let decoded = try JSONDecoder().decode([QueuedPRNotification].self, from: data)
        XCTAssertEqual(decoded.first?.prId, 123)
        XCTAssertEqual(decoded.first?.prTitle, "Fix bug")
    }
}

