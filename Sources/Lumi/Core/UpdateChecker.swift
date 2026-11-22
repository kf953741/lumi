import Foundation

/// Strictly manual (user-initiated) GitHub Releases update checker.
/// Never performs background polling so Lumi keeps its 100% local, zero-telemetry guarantee.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case updateAvailable(latestTag: String, releaseURL: URL)
    case failed
}

public enum UpdateChecker {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/kf953741/lumi/releases/latest")!
    private static let fallbackReleasesURL = URL(string: "https://github.com/kf953741/lumi/releases")!

    public static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.3.0"
    }

    public static func checkLatest() async -> UpdateCheckResult {
        var req = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Lumi-macOS/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, !tag.isEmpty else {
                return .failed
            }
            let urlStr = (obj["html_url"] as? String) ?? ""
            let url = URL(string: urlStr) ?? fallbackReleasesURL
            if isNewer(tag, than: currentAppVersion) {
                return .updateAvailable(latestTag: tag, releaseURL: url)
            }
            return .upToDate(current: currentAppVersion)
        } catch {
            return .failed
        }
    }

    /// Compares semantic versions such as `"v1.3.0"` vs `"1.2.0"`.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        let rParts = parseVersion(remote)
        let lParts = parseVersion(local)
        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let rv = i < rParts.count ? rParts[i] : 0
            let lv = i < lParts.count ? lParts[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    private static func parseVersion(_ raw: String) -> [Int] {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
            .split(separator: "-").first.map(String.init) ?? ""
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }
}
