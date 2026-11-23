import Foundation

enum LaunchAgentManager {
    private static let label = "cc.bigsmart.Lumi"

    private static var defaultPlistURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        isEnabled(plistURL: defaultPlistURL)
    }

    static func isEnabled(plistURL: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = obj["ProgramArguments"] as? [String],
              let execPath = args.first, !execPath.isEmpty else {
            return false
        }
        return fm.isExecutableFile(atPath: execPath)
    }

    static func resolvedExecutablePath() -> String {
        let fm = FileManager.default
        // Prefer the currently running .app bundle (works for ~/Applications, custom folders, and /Applications)
        if let currentExec = Bundle.main.executablePath,
           Bundle.main.bundlePath.hasSuffix(".app"),
           fm.isExecutableFile(atPath: currentExec) {
            return currentExec
        }
        let systemApp = "/Applications/Lumi.app/Contents/MacOS/Lumi"
        if fm.isExecutableFile(atPath: systemApp) {
            return systemApp
        }
        let userApp = "\(NSHomeDirectory())/Applications/Lumi.app/Contents/MacOS/Lumi"
        if fm.isExecutableFile(atPath: userApp) {
            return userApp
        }
        return Bundle.main.executablePath ?? systemApp
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool, plistURL: URL = defaultPlistURL, executablePath: String? = nil) -> Bool {
        let fm = FileManager.default
        if enabled {
            let execPath = executablePath ?? resolvedExecutablePath()
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            do {
                try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
                return true
            } catch {
                return false
            }
        } else {
            guard fm.fileExists(atPath: plistURL.path) else { return true }
            do {
                try fm.removeItem(at: plistURL)
                return true
            } catch {
                return false
            }
        }
    }
}
