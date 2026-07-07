import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Browser OAuth (Authorization Code + PKCE) for Google Drive — the iOS analog of
/// the Android app's AppAuth fallback path. Built on `ASWebAuthenticationSession`,
/// so it pulls in no Google SDK (honoring the app's no-dependencies rule) and is
/// "the browser way to log in" the user already likes.
///
/// It reuses the OAuth client in the **same GCP project (297018645967)** as the
/// Android app. Google's `appDataFolder` is shared by every OAuth client in one
/// project, per user, so authenticating here reads/writes the exact hidden folder
/// the Android app already populates — the two apps become peers in one folder.
/// The client is an iOS-type client (reverse-client-ID redirect, no client
/// secret), which is exactly what a native PKCE public client needs.
///
/// The refresh token lives in the Keychain; the access token is cached in memory
/// and refreshed silently. This is deliberately independent of the iCloud sync —
/// it's a second, opt-in backend (see `DriveSync`).
@MainActor
final class DriveAuth: NSObject {
    /// Reverse-client-ID (iOS-type) OAuth client shared with the Android browser
    /// path. See ADR `nerlan-ios-google-drive-sync`.
    static let clientID = "297018645967-rt0483lsudd5k2ssncio8mtqak8537pu.apps.googleusercontent.com"
    static let redirectURI = "com.googleusercontent.apps.297018645967-rt0483lsudd5k2ssncio8mtqak8537pu:/oauth2redirect"
    private static let callbackScheme = "com.googleusercontent.apps.297018645967-rt0483lsudd5k2ssncio8mtqak8537pu"
    /// `drive.appdata` is the only data scope; `openid email` is just to label the
    /// signed-in account in Settings.
    static let scope = "https://www.googleapis.com/auth/drive.appdata openid email"

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let refreshTokenAccount = "drive-refresh-token"
    private static let emailDefaultsKey = "driveAccountEmail"

    /// Thrown when the stored refresh token is gone or revoked (e.g. the consent
    /// screen is still in "Testing", or the user revoked access) and the user must
    /// sign in through the browser again — the analog of Android's `ReauthRequired`.
    struct ReauthRequired: Error {}

    /// The auth sheet couldn't be presented (e.g. no key window yet), so its
    /// completion handler will never fire.
    struct PresentationFailed: LocalizedError {
        var errorDescription: String? { "無法開啟 Google 登入視窗，請再試一次。" }
    }

    private var cachedToken: String?
    private var cachedExpiry: Date?
    /// Held strongly for the duration of the flow — `ASWebAuthenticationSession`
    /// deallocates (and cancels) if not retained.
    private var session: ASWebAuthenticationSession?

    var email: String? { UserDefaults.standard.string(forKey: Self.emailDefaultsKey) }
    var isSignedIn: Bool { Keychain.get(Self.refreshTokenAccount) != nil }

    // MARK: - Interactive sign-in

    /// Open Google's consent page, exchange the returned code for tokens, and
    /// persist the refresh token. Throws if the user cancels or the exchange fails.
    func signIn() async throws {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(32)

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // offline + consent so Google returns a refresh token we can renew
            // silently between syncs.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: comps.url!, callbackURLScheme: Self.callbackScheme
            ) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? ReauthRequired()) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            // start() returning false means nothing was presented and the
            // completion handler will never be called — resume with an error,
            // or the continuation (and Settings' 登入中… spinner) hangs forever.
            if !session.start() {
                cont.resume(throwing: PresentationFailed())
            }
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw ReauthRequired()
        }
        try await exchangeCode(code, verifier: verifier)
    }

    func signOut() {
        Keychain.delete(Self.refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: Self.emailDefaultsKey)
        cachedToken = nil
        cachedExpiry = nil
    }

    // MARK: - Access token for sync

    /// A valid `drive.appdata` access token, refreshed silently when expired.
    /// Throws `ReauthRequired` when the refresh token is missing or rejected.
    func accessToken() async throws -> String {
        if let token = cachedToken, let expiry = cachedExpiry, expiry.timeIntervalSinceNow > 60 {
            return token
        }
        guard let refresh = Keychain.get(Self.refreshTokenAccount) else { throw ReauthRequired() }

        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody([
            "client_id": Self.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // invalid_grant: the refresh token was revoked/expired. It's dead — drop the
        // session so the UI prompts a fresh browser login.
        if status == 400 || status == 401 {
            signOut()
            throw ReauthRequired()
        }
        guard status == 200, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw URLError(.badServerResponse)
        }
        cachedToken = token.access_token
        cachedExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        return token.access_token
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody([
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ReauthRequired()
        }
        if let refresh = token.refresh_token { Keychain.set(refresh, account: Self.refreshTokenAccount) }
        cachedToken = token.access_token
        cachedExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600))
        if let idToken = token.id_token, let email = Self.email(fromIDToken: idToken) {
            UserDefaults.standard.set(email, forKey: Self.emailDefaultsKey)
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
    }

    // MARK: - PKCE / helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(data)
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formBody(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }

    /// Pull the `email` claim out of the id_token JWT (no signature check needed —
    /// it came straight from Google's token endpoint over TLS).
    private static func email(fromIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }
}

extension DriveAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
    }
}
