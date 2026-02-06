# Pulse

A lightweight macOS menu bar app for tracking GitHub Pull Requests.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

### Three PR Views
- **Awaiting Review** - PRs where your review is requested
- **Involved** - PRs you're involved with (authored, commented, reviewed)
- **My PRs** - Your own pull requests with review status

### Smart Notifications
- Full-screen alerts for new PR review requests
- Configurable review reminders (5-60 min intervals)
- Snooze notifications for 5 minutes
- Activity notifications for your PRs (approvals, comments, CI status, merges)

### Review Status Tracking
- See approval/changes requested/comment counts on your PRs
- Filter My PRs by state (Open, Closed, Merged, All)
- Visual badges for draft, merged, and closed PRs

### Repository Filtering
- Monitor all repositories or select specific ones
- Shared filter across all tabs

### Additional Features
- Auto-refresh with configurable polling interval (1-30 min)
- Secure token storage in macOS Keychain
- Native macOS design with dark mode support
- Lives in menu bar - no dock icon

## Installation

### Download
Download the latest `.dmg` from [Releases](../../releases).

### Build from Source
```bash
# Clone the repository
git clone https://github.com/lluzak/pulse.git
cd pulse

# Set up OAuth credentials (required for GitHub sign-in)
cp pulse/Secrets.swift.template pulse/Secrets.swift
# Edit pulse/Secrets.swift with your GitHub OAuth App credentials
# Get them from: https://github.com/settings/developers

# Build and run
./run.sh

# Or create a DMG for distribution
./build.sh
```

## Setup

1. Click the Pulse icon in your menu bar
2. Click "Sign in with GitHub" and authorize the app

**Alternative:** Use a Personal Access Token
- Click "Use personal access token"
- Generate a token at [GitHub Settings](https://github.com/settings/tokens) with `repo` scope
- Paste the token and click "Sign In"

## Screenshots

*Coming soon*

## Requirements

- macOS 14.0 (Sonoma) or later
- GitHub account with Personal Access Token

## Building

```bash
# Development build
./run.sh              # Build and launch
./run.sh --debug      # Build with console output

# Production build
./build.sh            # Creates build/Pulse-{date}.dmg

# Run tests
xcodebuild -scheme pulse -destination 'platform=macOS' test
```

## Tech Stack

- SwiftUI
- Swift 6 with `@Observable` macro
- NSPopover for menu bar integration
- URLSession with async/await
- macOS Keychain for secure storage

## License

MIT License - see [LICENSE](LICENSE) for details.

---

Made with care for developers who review PRs.
