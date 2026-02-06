//
//  OAuthManager.swift
//  pulse
//
//  Created by Przemyslaw Lusar on 06/02/2026.
//

import Foundation
import CryptoKit
import AppKit

@Observable
class OAuthManager {
    static let shared = OAuthManager()

    private let clientID = Secrets.gitHubClientID
    private let clientSecret = Secrets.gitHubClientSecret
    private let redirectURI = "pulse://oauth/callback"
    private let scope = "repo"

    // PKCE state stored during auth flow
    private var codeVerifier: String?
    private var state: String?

    // Observable state
    var isAuthenticating = false
    var error: String?

    // Callback for when auth completes
    var onAuthSuccess: ((String) -> Void)?
    var onAuthFailure: ((String) -> Void)?

    private init() {}

    // MARK: - Start OAuth Flow

    func startOAuthFlow() {
        // Generate PKCE code verifier and challenge
        codeVerifier = generateCodeVerifier()
        guard let verifier = codeVerifier else {
            error = "Failed to generate code verifier"
            return
        }

        let challenge = generateCodeChallenge(from: verifier)

        // Generate random state for CSRF protection
        state = generateRandomString(length: 32)

        // Build authorization URL
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components.url else {
            error = "Failed to build authorization URL"
            return
        }

        isAuthenticating = true
        error = nil

        // Open browser
        NSWorkspace.shared.open(url)
    }

    // MARK: - Handle Callback

    func handleCallback(url: URL) -> Bool {
        guard url.scheme == "pulse",
              url.host == "oauth" || url.path.hasPrefix("/oauth") else {
            return false
        }

        // Parse query parameters
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            handleError("Invalid callback URL")
            return true
        }

        let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        // Check for error from GitHub
        if let errorCode = params["error"] {
            let errorDescription = params["error_description"] ?? errorCode
            handleError(errorDescription)
            return true
        }

        // Verify state matches
        guard let returnedState = params["state"], returnedState == state else {
            handleError("State mismatch - possible CSRF attack")
            return true
        }

        // Get authorization code
        guard let code = params["code"] else {
            handleError("No authorization code received")
            return true
        }

        // Exchange code for token
        Task {
            await exchangeCodeForToken(code: code)
        }

        return true
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String) async {
        guard let verifier = codeVerifier else {
            await MainActor.run {
                handleError("Missing code verifier")
            }
            return
        }

        let url = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bodyParams = [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        request.httpBody = bodyString.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run {
                    handleError("Invalid response")
                }
                return
            }

            if httpResponse.statusCode != 200 {
                await MainActor.run {
                    handleError("Token exchange failed with status \(httpResponse.statusCode)")
                }
                return
            }

            // Parse response
            struct TokenResponse: Decodable {
                let access_token: String?
                let token_type: String?
                let scope: String?
                let error: String?
                let error_description: String?
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

            if let errorMsg = tokenResponse.error {
                let description = tokenResponse.error_description ?? errorMsg
                await MainActor.run {
                    handleError(description)
                }
                return
            }

            guard let accessToken = tokenResponse.access_token else {
                await MainActor.run {
                    handleError("No access token in response")
                }
                return
            }

            // Success!
            await MainActor.run {
                cleanup()
                isAuthenticating = false
                onAuthSuccess?(accessToken)
            }

        } catch {
            await MainActor.run {
                handleError("Network error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) {
        cleanup()
        isAuthenticating = false
        error = message
        onAuthFailure?(message)
    }

    private func cleanup() {
        codeVerifier = nil
        state = nil
    }

    func cancelAuth() {
        cleanup()
        isAuthenticating = false
        error = nil
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        // Generate 32 random bytes and base64url encode
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        // SHA256 hash of verifier, base64url encoded
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
}

// MARK: - Base64URL Encoding

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
