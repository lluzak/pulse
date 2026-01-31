# Pulse - GitHub PR Reviewer Menu Bar App

A macOS menu bar application for tracking GitHub Pull Requests that await your review.

## Features

### 🔔 Two View Modes
- **Awaiting Review**: PRs explicitly requesting your review (`review-requested:username`)
- **Involved**: All PRs you're involved with (`involves:username`)

### 🔄 Automatic Polling
- Polls GitHub API every 5 minutes (configurable)
- Manual refresh available via UI button
- Automatic start/stop when signing in/out

### 🔐 Secure Authentication
- GitHub Personal Access Token (fine-grained or classic)
- Securely stored in macOS Keychain
- Token persists across app launches

### 📊 Rich PR Information
- Repository name
- PR title and number
- Author information
- Code changes (+additions/-deletions)
- Last updated time (relative)
- Draft status indicator

### 🎨 Clean UI
- Compact menu bar popover (400x550)
- Tabbed interface for different PR views
- Badge counts on tabs
- Empty states with helpful messages
- Click any PR to open in browser

## Setup

### 1. Generate GitHub Personal Access Token

#### For Fine-Grained Tokens (Recommended):
1. Go to [GitHub Settings → Developer settings → Personal access tokens → Fine-grained tokens](https://github.com/settings/tokens?type=beta)
2. Click "Generate new token"
3. Configure:
   - **Token name**: "Pulse PR Reviewer"
   - **Expiration**: Choose your preference
   - **Repository access**: 
     - Select "All repositories" OR
     - Select specific repositories you want to monitor
   - **Permissions**:
     - Repository permissions → Pull requests: **Read-only**
     - Repository permissions → Metadata: **Read-only** (auto-selected)
4. Click "Generate token"
5. Copy the token immediately (you won't see it again!)

#### For Classic Tokens:
1. Go to [GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens)
2. Click "Generate new token (classic)"
3. Select scopes:
   - ✅ `repo` (Full control of private repositories)
   - ✅ `read:org` (Read org membership - optional, for organization PRs)
4. Click "Generate token"
5. Copy the token

### 2. Sign In to Pulse
1. Launch Pulse (appears in menu bar with waveform icon)
2. Click the menu bar icon
3. Paste your token
4. Click "Sign In"

### 3. Start Monitoring
- Switch between "Awaiting Review" and "Involved" tabs
- Click any PR to open it in your browser
- Click refresh icon to manually update
- PRs auto-refresh every 5 minutes

## Architecture

### GitHubService
Observable class managing:
- Authentication state
- API calls to GitHub
- Periodic polling
- Two separate PR lists (awaiting review + involved)
- Keychain integration for secure token storage

### Views
- **ContentView**: Main entry point, shows auth or PR list
- **GitHubAuthView**: Token input and authentication
- **PRListView**: Tabbed interface for viewing PRs
- **PRRowView**: Individual PR display with hover effects

### Models
- **GitHubUser**: Current user information
- **PullRequest**: Full PR details with computed properties
- **GitHubSearchResponse**: Search API response wrapper
- **PRUser, PRBranch, PRRepository**: Supporting structures

## Configuration

### Polling Interval
```swift
// Default: 5 minutes (300 seconds)
gitHubService.pollingInterval = 300

// Disable polling
gitHubService.isPollingEnabled = false
```

### Monitor Specific Repositories
```swift
// Monitor all repositories (default)
gitHubService.monitorAllRepositories = true

// Monitor specific repositories only
gitHubService.monitorAllRepositories = false
gitHubService.monitoredRepositories = [
    "owner/repo1",
    "owner/repo2",
    "company/project"
]
```

## Testing

Run tests in Xcode:
```bash
Cmd + U
```

### Test Coverage
- ✅ Service initialization and state
- ✅ Authentication and sign out
- ✅ Model JSON decoding
- ✅ Date parsing and formatting
- ✅ Keychain save/load/delete
- ✅ PR sorting and filtering
- ✅ Repository name extraction

## API Queries

### Awaiting Review Tab
```
type:pr state:open review-requested:{username}
```
Returns PRs where you're explicitly requested as a reviewer and haven't approved yet.

### Involved Tab  
```
type:pr state:open involves:{username}
```
Returns all open PRs you're involved with (author, commenter, mentioned, assignee, or reviewer).

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 6.0+
- GitHub account with Personal Access Token

## Privacy

- Token stored securely in macOS Keychain
- No data sent to third parties
- All GitHub API calls made directly from your machine
- No telemetry or analytics

## Troubleshooting

### "Cannot find server" error
1. Check your internet connection
2. Verify the app has network access entitlements
3. In Xcode: Project → Signing & Capabilities → App Sandbox → ✅ Outgoing Connections (Client)

### No PRs showing up
1. Check console output (Cmd+Shift+Y in Xcode) for API responses
2. Verify your token has correct permissions
3. Try manually searching GitHub with the same query
4. Check if your token has access to the repositories

### Token rejected
1. Verify token is copied correctly (no extra spaces)
2. Check token hasn't expired
3. Ensure token has required scopes/permissions
4. Try regenerating the token

## License

© 2026 Przemyslaw Lusar

## Contributing

This is a personal project, but feel free to fork and modify for your own use!
