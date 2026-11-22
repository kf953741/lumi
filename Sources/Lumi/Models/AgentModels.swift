import Foundation
import SwiftUI

// MARK: - Supported AI Coding Agents

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case antigravity
    case codex
    case claude
    case cursor
    case gemini
    case opencode

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .antigravity: return "AGY"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .opencode: return "OpenCode"
        }
    }

    public var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        }
    }

    public var accentColor: Color {
        switch self {
        case .antigravity: return Color(red: 0.74, green: 0.48, blue: 1.00)
        case .codex:       return Color(red: 0.16, green: 0.84, blue: 0.74)
        case .claude:      return Color(red: 0.96, green: 0.56, blue: 0.32)
        case .cursor:      return Color(red: 0.46, green: 0.72, blue: 1.00)
        case .gemini:      return Color(red: 0.36, green: 0.64, blue: 1.00)
        case .opencode:    return Color(red: 0.56, green: 0.86, blue: 0.44)
        }
    }

    public var targetBundleIDs: [String] {
        switch self {
        case .antigravity: return ["com.google.antigravity"]
        case .codex:       return ["com.openai.codex", "com.openai.chat"]
        case .claude:      return ["com.anthropic.claudefordesktop", "com.microsoft.VSCode", "com.googlecode.iterm2", "com.apple.Terminal"]
        case .cursor:      return ["com.todesktop.230313mzl4w4u92"]
        case .gemini:      return ["com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        case .opencode:    return ["com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.apple.Terminal"]
        }
    }

    public var hookDescription: String {
        switch self {
        case .antigravity: return "~/.gemini/config/hooks.json（+ 自动读取会话库）"
        case .codex:       return "~/.codex/hooks.json（+ 免配置自动追踪桌面版与 CLI）"
        case .claude:      return "~/.claude/settings.json（+ 自动读取本地会话）"
        case .cursor:      return "~/.cursor/hooks.json"
        case .gemini:      return "~/.gemini/settings.json"
        case .opencode:    return "~/.config/opencode/plugins/lumi.js"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case done
    case error
    case canceled
}

public enum AgentFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case antigravity = "AGY"
    case codex = "Codex"
    case claude = "Claude"
    case others = "其他"

    public var id: String { rawValue }

    public func matches(_ kind: AgentKind) -> Bool {
        switch self {
        case .all: return true
        case .antigravity: return kind == .antigravity
        case .codex: return kind == .codex
        case .claude: return kind == .claude
        case .others: return kind == .cursor || kind == .gemini || kind == .opencode
        }
    }
}

// MARK: - Window Mode & Mascot Themes

public enum DisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case notch = "notch"
    case floating = "floating"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .notch: return "刘海灵动岛"
        case .floating: return "桌面悬浮看板"
        }
    }
}

public enum MascotTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case ember   // 加州暖橘（默认主色）
    case butter  // 奶油杏黄
    case aurora  // 薄荷极光
    case nebula  // 星云淡紫
    case sakura  // 珊瑚莓粉
    case cloud   // 云朵奶白

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ember:  return "加州暖橘"
        case .butter: return "奶油杏黄"
        case .aurora: return "薄荷极光"
        case .nebula: return "星云淡紫"
        case .sakura: return "珊瑚莓粉"
        case .cloud:  return "云朵奶白"
        }
    }

    public var englishName: String {
        switch self {
        case .ember:  return "Ember"
        case .butter: return "Butter"
        case .aurora: return "Aurora"
        case .nebula: return "Nebula"
        case .sakura: return "Berry"
        case .cloud:  return "Cloud"
        }
    }

    public var bodyTop: Color {
        switch self {
        case .ember:  return Color(red: 0.965, green: 0.576, blue: 0.224) // #F69339
        case .butter: return Color(red: 1.000, green: 0.820, blue: 0.400) // #FFD166
        case .aurora: return Color(red: 0.300, green: 0.880, blue: 0.700) // #4CE0B3
        case .nebula: return Color(red: 0.663, green: 0.545, blue: 1.000) // #A98BFF
        case .sakura: return Color(red: 1.000, green: 0.561, blue: 0.659) // #FF8FA8
        case .cloud:  return Color(red: 0.915, green: 0.892, blue: 0.848) // #E9E3D8
        }
    }

    public var bodyMid: Color {
        switch self {
        case .ember:  return Color(red: 0.953, green: 0.482, blue: 0.259) // #F37B42
        case .butter: return Color(red: 0.975, green: 0.725, blue: 0.295)
        case .aurora: return Color(red: 0.195, green: 0.765, blue: 0.625)
        case .nebula: return Color(red: 0.545, green: 0.430, blue: 0.940)
        case .sakura: return Color(red: 0.960, green: 0.440, blue: 0.565)
        case .cloud:  return Color(red: 0.862, green: 0.832, blue: 0.780)
        }
    }

    public var bodyBottom: Color {
        switch self {
        case .ember:  return Color(red: 0.957, green: 0.408, blue: 0.286) // #F46849
        case .butter: return Color(red: 0.945, green: 0.612, blue: 0.230)
        case .aurora: return Color(red: 0.125, green: 0.643, blue: 0.541)
        case .nebula: return Color(red: 0.443, green: 0.333, blue: 0.898)
        case .sakura: return Color(red: 0.918, green: 0.353, blue: 0.490)
        case .cloud:  return Color(red: 0.800, green: 0.764, blue: 0.706)
        }
    }

    public var eyelidColor: Color {
        switch self {
        case .ember:  return Color(red: 0.890, green: 0.455, blue: 0.212) // #E37436
        case .butter: return Color(red: 0.875, green: 0.620, blue: 0.215)
        case .aurora: return Color(red: 0.145, green: 0.655, blue: 0.525)
        case .nebula: return Color(red: 0.465, green: 0.355, blue: 0.825)
        case .sakura: return Color(red: 0.855, green: 0.365, blue: 0.490)
        case .cloud:  return Color(red: 0.755, green: 0.718, blue: 0.660)
        }
    }

    public var specularColor: Color {
        switch self {
        case .ember:  return Color(red: 0.976, green: 0.620, blue: 0.350) // #F99E59
        case .butter: return Color(red: 1.000, green: 0.900, blue: 0.600)
        case .aurora: return Color(red: 0.550, green: 0.950, blue: 0.830)
        case .nebula: return Color(red: 0.790, green: 0.710, blue: 1.000)
        case .sakura: return Color(red: 1.000, green: 0.720, blue: 0.790)
        case .cloud:  return Color.white
        }
    }

    public var eyeGlow: Color {
        switch self {
        case .ember:  return Color(red: 1.000, green: 0.682, blue: 0.353) // #FFAE5A
        case .butter: return Color(red: 1.000, green: 0.860, blue: 0.480)
        case .aurora: return Color(red: 0.440, green: 0.945, blue: 0.790)
        case .nebula: return Color(red: 0.765, green: 0.690, blue: 1.000)
        case .sakura: return Color(red: 1.000, green: 0.700, blue: 0.775)
        case .cloud:  return Color(red: 1.000, green: 0.840, blue: 0.620)
        }
    }
}

public enum MascotMood: Equatable, Sendable {
    case sleeping
    case working
    case celebrating
    case waitingUnread
    case error
    case poked
    case dizzy
}

// MARK: - Core Session Model

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String                 // "<kind>:<rawId>"
    public let rawId: String
    public let kind: AgentKind
    public let title: String
    public let project: String
    public let cwd: String
    public let isCLI: Bool
    public let status: SessionStatus
    public let currentAction: String
    public let detailSummary: String
    public let startedAt: Date?
    public let updatedAt: Date
    public let completedAt: Date?
    public let durationSec: TimeInterval?
    public let activeSubagents: Int
    public var isUnread: Bool

    public init(
        id: String,
        rawId: String,
        kind: AgentKind,
        title: String,
        project: String,
        cwd: String,
        isCLI: Bool,
        status: SessionStatus,
        currentAction: String,
        detailSummary: String,
        startedAt: Date?,
        updatedAt: Date,
        completedAt: Date?,
        durationSec: TimeInterval?,
        activeSubagents: Int,
        isUnread: Bool
    ) {
        self.id = id
        self.rawId = rawId
        self.kind = kind
        self.title = title
        self.project = project
        self.cwd = cwd
        self.isCLI = isCLI
        self.status = status
        self.currentAction = currentAction
        self.detailSummary = detailSummary
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.durationSec = durationSec
        self.activeSubagents = activeSubagents
        self.isUnread = isUnread
    }
}

// MARK: - Formatting & Name Helpers

public enum ProjectNameHelper {
    private static let genericFolders: Set<String> = [
        "lib", "src", "app", "web", "client", "server", "api", "core",
        "pkg", "packages", "frontend", "backend", "scripts", "docs",
        "build", "dist", "outputs", "output", "workspace", "scratch",
        "new-chat", "new-chat-2", "new-chat-3", "config"
    ]

    public static func projectName(from rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "" }

        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        } else if path.contains("%") {
            path = path.removingPercentEncoding ?? path
        }

        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return "" }

        let parent = url.deletingLastPathComponent().lastPathComponent
        let grandParent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let userName = NSUserName()

        // Codex date folders like .../Codex/2026-10-31/new-chat-2
        if parent.count == 10, parent.contains("-"), parent.hasPrefix("202") {
            if last.hasPrefix("new-chat") {
                return "Codex · \(parent.suffix(5))"
            }
            return String(last.prefix(24))
        }

        // Disambiguate generic leaf folders like "lib" -> "google_sim/lib"
        if genericFolders.contains(last.lowercased()),
           !parent.isEmpty, parent != "/", parent != userName, parent != "Users" {
            if genericFolders.contains(parent.lowercased()), !grandParent.isEmpty, grandParent != userName {
                return "\(grandParent)/\(last)"
            }
            return "\(parent)/\(last)"
        }

        if last == userName || last == "Documents" {
            return "全局"
        }
        return last
    }

    public static func cleanOneLine(_ text: String, maxLength: Int = 96) -> String {
        var s = text
        if let start = s.range(of: "<USER_REQUEST>"), let end = s.range(of: "</USER_REQUEST>"),
           start.upperBound < end.lowerBound {
            s = String(s[start.upperBound..<end.lowerBound])
        }

        let lines = s
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("# Files mentioned") && !$0.hasPrefix("## ") }

        var chosen = lines.first ?? s
        chosen = chosen.replacingOccurrences(of: #"^[#>*`\-\s]+"#, with: "", options: .regularExpression)
        chosen = chosen.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        chosen = chosen.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)

        if chosen.count > maxLength {
            let idx = chosen.index(chosen.startIndex, offsetBy: maxLength - 1)
            return String(chosen[..<idx]) + "…"
        }
        return chosen
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return String(format: "%dm%02ds", mins, secs) }
        let hours = mins / 60
        let remMins = mins % 60
        return String(format: "%dh%02dm", hours, remMins)
    }

    public static func formatClock(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}

public enum ToolActionFormatter {
    public static func describe(name: String, rawInput: String) -> String {
        let low = name.lowercased()
        let compact = ProjectNameHelper.cleanOneLine(rawInput, maxLength: 40)

        if low == "exec" || low == "exec_command" || low == "shell" || low == "shell_command" || low == "bash" {
            if let data = rawInput.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cmd = (obj["cmd"] ?? obj["command"]) as? String {
                let clean = ProjectNameHelper.cleanOneLine(cmd, maxLength: 38)
                return clean.isEmpty ? "运行终端命令" : "运行 · \(clean)"
            }
            return compact.isEmpty ? "运行脚本/命令" : "执行 · \(compact)"
        }
        if low.contains("apply_patch") || low.contains("edit") || low.contains("write") {
            return "修改代码文件"
        }
        if low.contains("read") || low.contains("view") || low.contains("image") {
            return "查看文件/图片"
        }
        if low.contains("search") || low.contains("web") || low == "grep" || low == "glob" {
            return low.contains("web") ? "联网搜索" : "检索代码"
        }
        if low.contains("browser") || low.contains("open_page") || low.contains("playwright") {
            return "操作浏览器"
        }
        if low.contains("spawn") || low.contains("agent") || low == "task" {
            return "派发子 Agent"
        }
        if low == "update_plan" || low == "todowrite" {
            return "更新执行计划"
        }
        return name.isEmpty ? "执行工具中…" : "调用 \(name)"
    }
}
