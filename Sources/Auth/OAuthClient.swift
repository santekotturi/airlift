import Foundation
import AuthenticationServices
import UIKit

enum OAuthError: Error, LocalizedError {
    case notConfigured
    case userCancelled
    case missingAuthorizationCode
    case stateMismatch
    case tokenRequest(status: Int, body: String)
    case noRefreshToken
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OAuth is not configured. Fill in Config.xcconfig with your client ID."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .stateMismatch:
            return "OAuth state mismatch — the redirect did not match this sign-in attempt."
        case .tokenRequest(let status, let body):
            return "Token request failed (HTTP \(status)): \(body)"
        case .noRefreshToken:
            return "No refresh token available — please reconnect your Google account."
        case .malformedResponse:
            return "The token response could not be decoded."
        }
    }
}

/// Drives the OAuth 2.0 Authorization Code + PKCE flow against Google, and
/// refreshes access tokens. Holds no persistent state itself — token storage is
/// the caller's responsibility (see `KeychainTokenStore`).
@MainActor
final class OAuthClient: NSObject {
    private let session: URLSession
    private var webAuthSession: ASWebAuthenticationSession?

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Authorization

    /// Presents the Google consent screen and exchanges the resulting code for
    /// tokens. Requests `access_type=offline` + `prompt=consent` to guarantee a
    /// refresh token (PRD §6.3).
    func authorize() async throws -> StoredTokens {
        guard OAuthConfig.isConfigured else { throw OAuthError.notConfigured }

        let pkce = PKCE()
        let state = UUID().uuidString
        let authURL = buildAuthorizationURL(pkce: pkce, state: state)

        let callbackURL = try await presentWebAuth(url: authURL)
        let code = try extractCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code, verifier: pkce.verifier)
    }

    private func buildAuthorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: OAuthConfig.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: OAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: OAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfig.scopeString),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            // Force a refresh token even on re-consent.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    private func presentWebAuth(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: OAuthConfig.callbackScheme
            ) { callbackURL, error in
                if let error {
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.missingAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }

    private func extractCode(from url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        if items.first(where: { $0.name == "state" })?.value != expectedState {
            throw OAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.missingAuthorizationCode
        }
        return code
    }

    // MARK: - Token exchange & refresh

    private func exchangeCode(_ code: String, verifier: String) async throws -> StoredTokens {
        let form = [
            "client_id": OAuthConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": OAuthConfig.redirectURI,
        ]
        let response = try await postToken(form)
        guard let refresh = response.refreshToken else { throw OAuthError.noRefreshToken }
        return StoredTokens(
            accessToken: response.accessToken,
            refreshToken: refresh,
            accessTokenExpiry: Date().addingTimeInterval(response.expiresIn),
            scope: response.scope
        )
    }

    /// Exchanges a refresh token for a fresh access token. Google omits a new
    /// refresh token on refresh, so we carry the existing one forward.
    func refresh(_ tokens: StoredTokens) async throws -> StoredTokens {
        guard OAuthConfig.isConfigured else { throw OAuthError.notConfigured }
        let form = [
            "client_id": OAuthConfig.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ]
        let response = try await postToken(form)
        return StoredTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? tokens.refreshToken,
            accessTokenExpiry: Date().addingTimeInterval(response.expiresIn),
            scope: response.scope ?? tokens.scope
        )
    }

    private func postToken(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: OAuthConfig.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw OAuthError.tokenRequest(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder.googleHealth.decode(TokenResponse.self, from: data) else {
            throw OAuthError.malformedResponse
        }
        return decoded
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Subset of the OAuth token endpoint response we care about.
private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

extension OAuthClient: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
