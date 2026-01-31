# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pulse is a native macOS menu bar application for tracking GitHub Pull Requests awaiting your review. Built with SwiftUI for macOS 14.0+, it displays PRs in a popover accessed from the menu bar.

## Build Commands

```bash
# Development: build and run
./run.sh              # Build and launch
./run.sh --debug      # Build and launch with console output

# Production: create DMG for distribution
./build.sh            # Creates build/Pulse-{date}.dmg

# Notarization (for public distribution)
./notarize.sh         # Notarize the DMG (requires Apple Developer account)

# Manual commands
xcodebuild -scheme pulse -configuration Debug build
xcodebuild -scheme pulse -destination 'platform=macOS' test
xcodebuild -scheme pulse -destination 'platform=macOS' -only-testing:pulseTests/GitHubServiceTests test
xcodebuild -scheme pulse clean
```

In Xcode: ⌘B (build), ⌘R (run), ⌘U (test)

## Architecture

### Core Components

- **GitHubService** (`pulse/GitHubService.swift`): `@Observable` class managing all state and GitHub API interactions. Handles authentication, PR fetching, polling, and Keychain integration. Contains all data models (PullRequest, GitHubUser, etc.) and KeychainHelper.

- **pulseApp** (`pulse/pulseApp.swift`): App entry point with AppDelegate managing the NSPopover menu bar UI. Configures as accessory app (no dock icon).

- **Views** (`pulse/ContentView.swift`, `pulse/MenuBarView.swift`): SwiftUI views including GitHubAuthView, PRListView, PRRowView. ContentView switches between auth and PR list based on authentication state.

### Data Flow

1. User enters GitHub Personal Access Token → GitHubService validates via API → Token stored in Keychain
2. GitHubService polls GitHub Search API every 5 minutes for two queries:
   - `type:pr state:open review-requested:{username}` (Awaiting Review tab)
   - `type:pr state:open involves:{username}` (Involved tab)
3. New PRs trigger macOS notifications

### Key Patterns

- Uses Swift 6 `@Observable` macro for reactive state
- NSPopover attached to NSStatusItem for menu bar integration
- EventMonitor class detects outside clicks to close popover
- All network requests are async/await with URLSession

## Testing

Tests are in `pulseTests/pulseTests.swift`. Key test classes:
- GitHubServiceTests: Service initialization, auth flow, polling
- GitHubModelsTests: JSON decoding, date parsing
- KeychainHelperTests: Secure storage operations
- PRFilteringTests: Sorting, draft detection

Helper function `createMockPR()` available for creating test PullRequest objects.

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 6.0
- GitHub Personal Access Token with `pull_requests:read` permission
