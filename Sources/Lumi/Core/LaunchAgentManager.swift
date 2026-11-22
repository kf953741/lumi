import Foundation

enum LaunchAgentManager {
    private static let label = "cc.bigsmart.Lumi"

    private static var plistURL: URL {
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let appPath = "/Applications/Lumi.app/Contents/MacOS/Lumi"
            let execPath = fm.fileExists(atPath: appPath) ? appPath : (Bundle.main.executablePath ?? appPath)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL, options: .atomic)
            }
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}
