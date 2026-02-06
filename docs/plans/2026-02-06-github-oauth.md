# GitHub OAuth Authentication

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace token-based auth with GitHub OAuth using PKCE flow for better UX.

**Architecture:** PKCE OAuth flow with custom URL scheme callback. Browser-based authorization, token exchange via GitHub API, stored in Keychain.

**Tech Stack:** SwiftUI, URLSession, CryptoKit (SHA256), Keychain

---

## Overview

User clicks "Sign in with GitHub" → browser opens → user authorizes → redirects back to app via `pulse://oauth/callback` → app exchanges code for token.

Token input remains as fallback option ("Use personal access token" link).

## OAuth Flow

1. User clicks "Sign in with GitHub"
2. App generates PKCE code verifier (random 43-128 char string) + challenge (SHA256 of verifier, base64url encoded)
3. App opens browser to:
   ```
   https://github.com/login/oauth/authorize
     ?client_id={CLIENT_ID}
     &redirect_uri=pulse://oauth/callback
     &scope=repo
     &state={random}
     &code_challenge={challenge}
     &code_challenge_method=S256
   ```
4. User authorizes on GitHub
5. GitHub redirects to `pulse://oauth/callback?code={code}&state={state}`
6. macOS routes URL to Pulse app via URL scheme handler
7. App verifies state matches, exchanges code for token:
   ```
   POST https://github.com/login/oauth/access_token
   Content-Type: application/x-www-form-urlencoded
   Accept: application/json

   client_id={CLIENT_ID}
   &code={code}
   &redirect_uri=pulse://oauth/callback
   &code_verifier={verifier}
   ```
8. GitHub returns `{"access_token": "...", "token_type": "bearer", "scope": "repo"}`
9. Token stored in Keychain (same as current flow)

## Scopes

- `repo` - Full access to private and public repositories (same as current token)

## Components

### 1. Info.plist - URL Scheme Registration
Register `pulse` as URL scheme so macOS routes `pulse://` URLs to the app.

### 2. OAuthManager (new class)
- `clientID: String` - hardcoded GitHub OAuth App client ID
- `codeVerifier: String?` - stored during auth flow
- `state: String?` - CSRF protection
- `startOAuthFlow()` - generate PKCE params, open browser
- `handleCallback(url: URL) -> Bool` - validate state, extract code
- `exchangeCodeForToken(code: String) async throws -> String` - POST to GitHub
- PKCE helpers: `generateCodeVerifier()`, `generateCodeChallenge(verifier:)`

### 3. AppDelegate Changes
- Implement `application(_:open:)` to catch callback URL
- Route URL to OAuthManager
- Notify GitHubService on success

### 4. GitHubService Changes
- Add `isAuthenticating: Bool` state for OAuth in-progress
- Add `authenticateWithOAuth(token:)` method (same as current token auth)

### 5. GitHubAuthView Changes
- Primary: "Sign in with GitHub" button (blue, prominent)
- Loading state with spinner while OAuth in progress
- Secondary: "Use personal access token" link (gray, below)
- Expandable token input field when link clicked
- Error handling for OAuth failures

## UI Mockup

```
┌─────────────────────────────────────┐
│                                     │
│         [GitHub Icon]               │
│                                     │
│      Connect to GitHub              │
│  Sign in to view your pending PRs   │
│                                     │
│   ┌─────────────────────────────┐   │
│   │   Sign in with GitHub  →    │   │  ← Primary button
│   └─────────────────────────────┘   │
│                                     │
│     Use personal access token       │  ← Secondary link
│                                     │
└─────────────────────────────────────┘
```

When "Use personal access token" clicked:
```
┌─────────────────────────────────────┐
│   ┌─────────────────────────────┐   │
│   │   Sign in with GitHub  →    │   │
│   └─────────────────────────────┘   │
│                                     │
│     ▼ Use personal access token     │
│                                     │
│   Personal Access Token             │
│   ┌─────────────────────────────┐   │
│   │ ghp_...                  👁  │   │
│   └─────────────────────────────┘   │
│   ┌─────────────────────────────┐   │
│   │        Sign In              │   │
│   └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

## GitHub OAuth App Setup (Manual)

1. Go to https://github.com/settings/developers
2. Click "New OAuth App"
3. Fill in:
   - Application name: `Pulse`
   - Homepage URL: `https://github.com/lluzak/pulse`
   - Authorization callback URL: `pulse://oauth/callback`
4. Click "Register application"
5. Copy the Client ID (will be hardcoded in app)
6. No client secret needed (PKCE flow)

## Error Handling

- User cancels in browser → App stays on auth screen, no error
- OAuth callback with error → Show error message
- Token exchange fails → Show "Authentication failed" with retry option
- Network error → Show network error message

## Security Considerations

- PKCE prevents authorization code interception
- State parameter prevents CSRF attacks
- Token stored in Keychain (encrypted by macOS)
- No client secret in app (public client with PKCE)

---

## Tasks

### Task 1: Register URL Scheme
**Files:** `pulse/Info.plist` (or via Xcode project settings)

Add URL scheme `pulse` to handle `pulse://` callbacks.

### Task 2: Create OAuthManager
**Files:** Create `pulse/OAuthManager.swift`

Implement PKCE generation, browser launch, and token exchange.

### Task 3: Handle URL Callback in AppDelegate
**Files:** Modify `pulse/pulseApp.swift`

Add `application(_:open:)` to catch OAuth callback and route to OAuthManager.

### Task 4: Update GitHubService
**Files:** Modify `pulse/GitHubService.swift`

Add OAuth-related state and integrate with OAuthManager.

### Task 5: Update Auth UI
**Files:** Modify `pulse/ContentView.swift`

New "Sign in with GitHub" button, collapsible token input as fallback.

### Task 6: Add Tests
**Files:** Modify `pulseTests/pulseTests.swift`

Test PKCE generation, URL parsing, token exchange mocking.

### Task 7: Integration Testing
Manual test of full OAuth flow end-to-end.
