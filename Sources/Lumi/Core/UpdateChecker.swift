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
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.4.0"
    }

    public static func checkLatest() async -> UpdateCheckResult {
        var req = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Lumi-macOS/\(currentAppVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, !tag.isEmpty,
                  parseVersion(tag) != nil else {
                return .failed
            }
            let urlStr = (obj["html_url"] as? String) ?? ""
            let url = validatedReleaseURL(from: urlStr)
            if isNewer(tag, than: currentAppVersion) {
                return .updateAvailable(latestTag: tag, releaseURL: url)
            }
            return .upToDate(current: currentAppVersion)
        } catch {
            return .failed
        }
    }

    /// Validates that a remote release URL points strictly to HTTPS `github.com/kf953741/lumi/...`.
    public static func validatedReleaseURL(from raw: String) -> URL {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.path.lowercased().hasPrefix("/kf953741/lumi/") else {
            return fallbackReleasesURL
        }
        return url
    }

    /// Compares semantic versions such as `"v1.3.0+build4"` vs `"1.2.0"` and handles prereleases (`1.4.0` > `1.4.0-beta.1`).
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let r = parseVersion(remote), let l = parseVersion(local) else { return false }
        let count = max(r.core.count, l.core.count)
        for i in 0..<count {
            let rv = i < r.core.count ? r.core[i] : 0
            let lv = i < l.core.count ? l.core[i] : 0
            if rv != lv { return rv > lv }
        }
        // Same numeric core: stable release is newer than a prerelease
        if r.prerelease == nil && l.prerelease != nil { return true }
        if r.prerelease != nil && l.prerelease == nil { return false }
        if let rp = r.prerelease, let lp = l.prerelease {
            return rp.compare(lp, options: .numeric) == .orderedDescending
        }
        return false
    }

    public static func isValidVersionTag(_ raw: String) -> Bool {
        parseVersion(raw) != nil
    }

    private static func parseVersion(_ raw: String) -> (core: [Int], prerelease: String?)? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        if let plusIdx = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIdx])
        }
        let coreStr: String
        let pre: String?
        if let dashIdx = cleaned.firstIndex(of: "-") {
            coreStr = String(cleaned[..<dashIdx])
            let p = String(cleaned[cleaned.index(after: dashIdx)...])
            pre = p.isEmpty ? nil : p
        } else {
            coreStr = cleaned
            pre = nil
        }
        let parts = coreStr.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var nums: [Int] = []
        for part in parts {
            guard !part.isEmpty, let n = Int(part), n >= 0 else { return nil }
            nums.append(n)
        }
        return (nums, pre)
    }
}
