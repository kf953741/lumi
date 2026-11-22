import Foundation

/// Safe, backup-first, one-click hook installer/uninstaller for all 6 supported AI coding agents.
enum HookInstaller {
    static var hookScriptPath: String {
        "\(NSHomeDirectory())/.lumi/lumi-hook.py"
    }

    private static var commandPrefix: String {
        "/usr/bin/python3 \"\(hookScriptPath)\""
    }

    static func ensureHookScriptInstalled() {
        let fm = FileManager.default
        let dir = "\(NSHomeDirectory())/.lumi"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: "\(dir)/live", withIntermediateDirectories: true)

        if let bundled = Bundle.main.path(forResource: "lumi-hook", ofType: "py") {
            try? fm.removeItem(atPath: hookScriptPath)
            try? fm.copyItem(atPath: bundled, toPath: hookScriptPath)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
        }
    }

    static func isInstalled(for kind: AgentKind) -> Bool {
        switch kind {
        case .antigravity:
            guard let root = readJSON(at: agyHooksPath) else { return false }
            return root["lumi"] != nil
        case .codex:
            return containsLumiCommand(at: codexHooksPath)
        case .claude:
            return containsLumiCommand(at: claudeSettingsPath)
        case .gemini:
            return containsLumiCommand(at: geminiSettingsPath)
        case .cursor:
            return containsLumiCommand(at: cursorHooksPath)
        case .opencode:
            return FileManager.default.fileExists(atPath: openCodePluginPath)
        }
    }

    static func install(for kind: AgentKind) throws {
        ensureHookScriptInstalled()
        switch kind {
        case .antigravity: try installAntigravity()
        case .codex:       try installCodex()
        case .claude:      try installClaude()
        case .gemini:      try installGemini()
        case .cursor:      try installCursor()
        case .opencode:    try installOpenCode()
        }
    }

    static func uninstall(for kind: AgentKind) throws {
        switch kind {
        case .antigravity: try uninstallAntigravity()
        case .codex:       try removeFromGroupedHooks(at: codexHooksPath)
        case .claude:      try removeFromGroupedHooks(at: claudeSettingsPath)
        case .gemini:      try removeFromGroupedHooks(at: geminiSettingsPath)
        case .cursor:      try removeFromGroupedHooks(at: cursorHooksPath)
        case .opencode:
            if FileManager.default.fileExists(atPath: openCodePluginPath) {
                try FileManager.default.removeItem(atPath: openCodePluginPath)
            }
        }
    }

    // MARK: - Paths

    private static var agyHooksPath: String { "\(NSHomeDirectory())/.gemini/config/hooks.json" }
    private static var codexHooksPath: String { "\(NSHomeDirectory())/.codex/hooks.json" }
    private static var claudeSettingsPath: String { "\(NSHomeDirectory())/.claude/settings.json" }
    private static var geminiSettingsPath: String { "\(NSHomeDirectory())/.gemini/settings.json" }
    private static var cursorHooksPath: String { "\(NSHomeDirectory())/.cursor/hooks.json" }
    private static var openCodePluginPath: String { "\(NSHomeDirectory())/.config/opencode/plugins/lumi.js" }

    // MARK: - Antigravity

    private static func installAntigravity() throws {
        var root = readJSON(at: agyHooksPath) ?? [:]
        // Migrate old temporary key if present
        root.removeValue(forKey: "agent-board")

        let cmd = "\(commandPrefix) --agent antigravity"
        root["lumi"] = [
            "PreInvocation": [["type": "command", "command": "\(cmd) PreInvocation", "timeout": 5]],
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "\(cmd) PreToolUse", "timeout": 5]]]],
            "PostToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "\(cmd) PostToolUse", "timeout": 5]]]],
            "Stop": [["type": "command", "command": "\(cmd) Stop", "timeout": 5]]
        ]
        try writeJSON(root, to: agyHooksPath)
    }

    private static func uninstallAntigravity() throws {
        guard var root = readJSON(at: agyHooksPath) else { return }
        root.removeValue(forKey: "lumi")
        root.removeValue(forKey: "agent-board")
        try writeJSON(root, to: agyHooksPath)
    }

    // MARK: - Codex / Claude / Gemini / Cursor

    private static func installCodex() throws {
        let cmd = "\(commandPrefix) --agent codex"
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
        try mergeIntoGroupedHooks(at: codexHooksPath, events: events, command: cmd, matcher: nil)
    }

    private static func installClaude() throws {
        let cmd = "\(commandPrefix) --agent claude"
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
        try mergeIntoGroupedHooks(at: claudeSettingsPath, events: events, command: cmd, matcher: nil)
    }

    private static func installGemini() throws {
        let cmd = "\(commandPrefix) --agent gemini"
        let events = ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent"]
        try mergeIntoGroupedHooks(at: geminiSettingsPath, events: events, command: cmd, matcher: "*")
    }

    private static func installCursor() throws {
        let cmd = "\(commandPrefix) --agent cursor"
        let events = ["beforeSubmitPrompt", "beforeShellExecution", "afterFileEdit", "stop"]
        try mergeIntoGroupedHooks(at: cursorHooksPath, events: events, command: cmd, matcher: nil)
    }

    private static func installOpenCode() throws {
        let fm = FileManager.default
        let dir = (openCodePluginPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let js = """
        // Lumi hook plugin for OpenCode — fire-and-forget session reporter
        import { spawn } from "node:child_process";

        const HOOK = "\(hookScriptPath)";
        function send(event, payload) {
          try {
            const p = spawn("/usr/bin/python3", [HOOK, "--agent", "opencode", event], { stdio: ["pipe", "ignore", "ignore"] });
            p.stdin.end(JSON.stringify(payload));
          } catch {}
        }

        export const LumiPlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            const sid = event?.properties?.sessionID || directory || "opencode";
            if (event?.type === "session.busy") send("session.busy", { session_id: sid, cwd: directory });
            if (event?.type === "session.idle") send("session.idle", { session_id: sid, cwd: directory });
          }
        });
        """
        try js.write(toFile: openCodePluginPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Generic JSON Hook Helpers

    private static func mergeIntoGroupedHooks(at path: String, events: [String], command: String, matcher: String?) throws {
        var root = readJSON(at: path) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for ev in events {
            var groups = hooks[ev] as? [[String: Any]] ?? []
            groups = stripLumiGroups(from: groups)
            let entry: [String: Any] = ["type": "command", "command": "\(command) \(ev)", "timeout": 5]
            var group: [String: Any] = ["hooks": [entry]]
            if let matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[ev] = groups
        }
        root["hooks"] = hooks
        try writeJSON(root, to: path)
    }

    private static func removeFromGroupedHooks(at path: String) throws {
        guard var root = readJSON(at: path),
              var hooks = root["hooks"] as? [String: Any] else { return }
        for key in Array(hooks.keys) {
            if let groups = hooks[key] as? [[String: Any]] {
                let cleaned = stripLumiGroups(from: groups)
                if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeJSON(root, to: path)
    }

    private static func stripLumiGroups(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let inner = group["hooks"] as? [[String: Any]] else { return group }
            let kept = inner.filter { h in
                let cmd = h["command"] as? String ?? ""
                return !cmd.contains("lumi-hook.py")
            }
            if kept.isEmpty { return nil }
            var copy = group
            copy["hooks"] = kept
            return copy
        }
    }

    private static func containsLumiCommand(at path: String) -> Bool {
        guard let str = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return str.contains("lumi-hook.py")
    }

    private static func readJSON(at path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: path) {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backup = "\(path).bak-\(fmt.string(from: Date()))"
            try? fm.copyItem(atPath: path, toPath: backup)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
