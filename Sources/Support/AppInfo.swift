import Foundation
import UIKit

/// App metadata and the links the UI points at — one place so the repo URL and
/// version string never drift between the About screen, onboarding, and bug
/// reports.
enum AppInfo {
    /// Public source repository. Used by the About link and bug reporting.
    static let repositoryURL = URL(string: "https://github.com/santekotturi/airlift")!

    /// Marketing version, e.g. "0.1.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Build number, e.g. "1".
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Hardware identifier, e.g. "iPhone16,2". More useful in a bug report than
    /// `UIDevice.model`, which only ever says "iPhone".
    static var deviceModelIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            raw.prefix { $0 != 0 }.map { Character(UnicodeScalar($0)) }
        }
        return machine.isEmpty ? "unknown" : String(machine)
    }

    /// Environment block appended to a bug report so issues arrive with the
    /// context needed to reproduce — no personal or health data, only versions.
    static var diagnosticsBlock: String {
        """
        ---
        - Airlift \(version) (\(build))
        - \(deviceModelIdentifier), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        """
    }

    /// A prefilled "new issue" URL on the public repo. GitHub fills the issue
    /// form from the query — nothing is sent until the user submits it there,
    /// so this needs no token and no server (keeping the app on-device).
    static func newIssueURL(title: String, body: String, labels: [String] = ["bug"]) -> URL? {
        var components = URLComponents(
            url: repositoryURL.appendingPathComponent("issues/new"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: labels.joined(separator: ",")),
        ]
        return components?.url
    }
}
