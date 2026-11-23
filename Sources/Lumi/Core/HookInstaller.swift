import Darwin
import Foundation

enum HookInstallerError: LocalizedError, Equatable {
    case invalidExistingJSON(path: String)
    case backupFailed(path: String, reason: String)
    case hookExecutableUnavailable
    case foreignPluginFile(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidExistingJSON(let path):
            return "Existing config is not valid standard JSON (comments/trailing commas or syntax error). Refused to overwrite: \(path)"
        case .backupFailed(let path, let reason):
            return "Failed to back up existing config before modifying \(path): \(reason)"
        case .hookExecutableUnavailable:
            return "Lumi hook relay executable is unavailable. Launch Lumi.app from Applications and retry."
        case .foreignPluginFile(let path):
            return "Refused to remove \(path) because it does not appear to be managed by Lumi."
        }
    }
}

/// Safe, backup-first, one-click hook installer/uninstaller for all supported AI coding agents.
/// Prefers Lumi's native built-in `Lumi --hook` entrypoint (zero Python/Xcode CLT dependency).
enum HookInstaller {
    static let openCodeOwnershipMarker = "LUMI_MANAGED_OPENCODE_PLUGIN"
    static let legacyOpenCodeMarker = "Lumi hook plugin for OpenCode"

    struct Config {
        let homeDir: String
        let nativeExecutablePath: String?
        let fallbackPythonPath: String?
        let codexHome: String
        let claudeHome: String
        let t3Home: String

        static var live: Config {
            let env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            let codexHome = nonEmptyEnv(env["CODEX_HOME"]) ?? "\(home)/.codex"
            let claudeHome = nonEmptyEnv(env["CLAUDE_CONFIG_DIR"]) ?? "\(home)/.claude"
            let t3Home = nonEmptyEnv(env["T3CODE_HOME"]) ?? "\(home)/.t3"
            return Config(
                homeDir: home,
                nativeExecutablePath: resolveNativeLumiExecutable(),
                fallbackPythonPath: resolveNonStubPython3(),
                codexHome: codexHome,
                claudeHome: claudeHome,
                t3Home: t3Home
            )
        }

        private static func nonEmptyEnv(_ raw: String?) -> String? {
            guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return (t as NSString).expandingTildeInPath
        }

        var hookScriptPath: String { "\(homeDir)/.lumi/lumi-hook.py" }
        var agyHooksPath: String { "\(homeDir)/.gemini/config/hooks.json" }
        var codexHooksPath: String { "\(codexHome)/hooks.json" }
        var claudeSettingsPath: String { "\(claudeHome)/settings.json" }
        var geminiSettingsPath: String { "\(homeDir)/.gemini/settings.json" }
        var cursorHooksPath: String { "\(homeDir)/.cursor/hooks.json" }
        var openCodePluginPath: String { "\(homeDir)/.config/opencode/plugins/lumi.js" }
        var t3StateV2Path: String { "\(t3Home)/userdata/statev2.sqlite" }
        var t3StateV1Path: String { "\(t3Home)/userdata/state.sqlite" }
    }

    static var hookScriptPath: String {
        Config.live.hookScriptPath
    }

    private static func resolveNativeLumiExecutable() -> String? {
        let fm = FileManager.default
        if let bundleExec = Bundle.main.executablePath,
           Bundle.main.bundlePath.hasSuffix(".app"),
           fm.isExecutableFile(atPath: bundleExec) {
            return bundleExec
        }
        let appExec = "/Applications/Lumi.app/Contents/MacOS/Lumi"
        if fm.isExecutableFile(atPath: appExec) {
            return appExec
        }
        let userAppExec = "\(NSHomeDirectory())/Applications/Lumi.app/Contents/MacOS/Lumi"
        if fm.isExecutableFile(atPath: userAppExec) {
            return userAppExec
        }
        return nil
    }

    /// Finds a real Python 3 binary that will NOT trigger macOS's Xcode CLT GUI install dialog.
    private static func resolveNonStubPython3() -> String? {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Only trust /usr/bin/python3 if Command Line Tools / Xcode is actually installed
        let cltMarkers = [
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        ]
        if cltMarkers.contains(where: { fm.isExecutableFile(atPath: $0) }),
           fm.isExecutableFile(atPath: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        return nil
    }

    private static func commandPrefix(config: Config) throws -> String {
        let fm = FileManager.default
        if let native = config.nativeExecutablePath, fm.isExecutableFile(atPath: native) {
            return "\"\(native)\" --hook"
        }
        if let py = config.fallbackPythonPath,
           fm.isExecutableFile(atPath: py),
           fm.fileExists(atPath: config.hookScriptPath) {
            return "\"\(py)\" \"\(config.hookScriptPath)\""
        }
        throw HookInstallerError.hookExecutableUnavailable
    }

    private static func spawnSpec(config: Config) throws -> (executable: String, baseArgs: [String]) {
        let fm = FileManager.default
        if let native = config.nativeExecutablePath, fm.isExecutableFile(atPath: native) {
            return (native, ["--hook"])
        }
        if let py = config.fallbackPythonPath,
           fm.isExecutableFile(atPath: py),
           fm.fileExists(atPath: config.hookScriptPath) {
            return (py, [config.hookScriptPath])
        }
        throw HookInstallerError.hookExecutableUnavailable
    }

    static func ensureHookScriptInstalled(config: Config = .live) {
        let fm = FileManager.default
        let dir = "\(config.homeDir)/.lumi"
        let liveDir = "\(dir)/live"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(atPath: liveDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(dir, 0o700)
        _ = chmod(liveDir, 0o700)

        if let bundled = Bundle.main.path(forResource: "lumi-hook", ofType: "py") {
            try? fm.removeItem(atPath: config.hookScriptPath)
            try? fm.copyItem(atPath: bundled, toPath: config.hookScriptPath)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: config.hookScriptPath)
        }
    }

    static func isInstalled(for kind: AgentKind, config: Config = .live) -> Bool {
        switch kind {
        case .antigravity:
            guard let root = try? readExistingJSONObject(at: config.agyHooksPath) else { return false }
            return root["lumi"] != nil
        case .codex:
            return containsLumiCommand(at: config.codexHooksPath)
        case .claude:
            return containsLumiCommand(at: config.claudeSettingsPath)
        case .t3code:
            let fm = FileManager.default
            return fm.fileExists(atPath: config.t3StateV2Path) || fm.fileExists(atPath: config.t3StateV1Path)
        case .gemini:
            return containsLumiCommand(at: config.geminiSettingsPath)
        case .cursor:
            return containsLumiCommand(at: config.cursorHooksPath)
        case .opencode:
            return isManagedOpenCodePlugin(at: config.openCodePluginPath)
        }
    }

    static func install(for kind: AgentKind, config: Config = .live) throws {
        ensureHookScriptInstalled(config: config)
        switch kind {
        case .antigravity: try installAntigravity(config: config)
        case .codex:       try installCodex(config: config)
        case .claude:      try installClaude(config: config)
        case .t3code:      break // Zero-config native SQLite watch — no hook file needed
        case .gemini:      try installGemini(config: config)
        case .cursor:      try installCursor(config: config)
        case .opencode:    try installOpenCode(config: config)
        }
    }

    static func uninstall(for kind: AgentKind, config: Config = .live) throws {
        switch kind {
        case .antigravity: try uninstallAntigravity(config: config)
        case .codex:       try removeFromGroupedHooks(at: config.codexHooksPath)
        case .claude:      try removeFromGroupedHooks(at: config.claudeSettingsPath)
        case .t3code:      break // Zero-config native SQLite watch — no hook file needed
        case .gemini:      try removeFromGroupedHooks(at: config.geminiSettingsPath)
        case .cursor:      try removeFromCursorHooks(at: config.cursorHooksPath)
        case .opencode:    try uninstallOpenCode(config: config)
        }
    }

    // MARK: - Antigravity

    private static func installAntigravity(config: Config) throws {
        let prefix = try commandPrefix(config: config)
        var root = try readExistingJSONObject(at: config.agyHooksPath) ?? [:]
        root.removeValue(forKey: "agent-board")

        let cmd = "\(prefix) --agent antigravity"
        root["lumi"] = [
            "PreInvocation": [["type": "command", "command": "\(cmd) PreInvocation", "timeout": 5]],
            "PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "\(cmd) PreToolUse", "timeout": 5]]]],
            "PostToolUse": [["matcher": "*", "hooks": [["type": "command", "command": "\(cmd) PostToolUse", "timeout": 5]]]],
            "Stop": [["type": "command", "command": "\(cmd) Stop", "timeout": 5]]
        ]
        try writeJSON(root, to: config.agyHooksPath)
    }

    private static func uninstallAntigravity(config: Config) throws {
        guard var root = try readExistingJSONObject(at: config.agyHooksPath) else { return }
        root.removeValue(forKey: "lumi")
        root.removeValue(forKey: "agent-board")
        try writeJSON(root, to: config.agyHooksPath)
    }

    // MARK: - Codex / Claude / Gemini

    private static func installCodex(config: Config) throws {
        let cmd = "\(try commandPrefix(config: config)) --agent codex"
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "Interrupt", "SessionEnd"]
        try mergeIntoGroupedHooks(at: config.codexHooksPath, events: events, command: cmd, matcher: nil)
    }

    private static func installClaude(config: Config) throws {
        let cmd = "\(try commandPrefix(config: config)) --agent claude"
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
        try mergeIntoGroupedHooks(at: config.claudeSettingsPath, events: events, command: cmd, matcher: nil)
    }

    private static func installGemini(config: Config) throws {
        let cmd = "\(try commandPrefix(config: config)) --agent gemini"
        let events = ["BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent"]
        try mergeIntoGroupedHooks(at: config.geminiSettingsPath, events: events, command: cmd, matcher: "*")
    }

    // MARK: - Cursor (Official Flat Format: { version: 1, hooks: { event: [{ command }] } })

    private static func installCursor(config: Config) throws {
        let cmd = "\(try commandPrefix(config: config)) --agent cursor"
        // Use passive post-hooks (`afterShellExecution`, `afterFileEdit`, `stop`) + `beforeSubmitPrompt`
        // so Lumi NEVER sits in Cursor's shell/MCP permission gate.
        let events = ["beforeSubmitPrompt", "afterShellExecution", "afterFileEdit", "stop"]
        var root = try readExistingJSONObject(at: config.cursorHooksPath) ?? [:]
        if root["version"] == nil {
            root["version"] = 1
        }
        var hooks: [String: Any]
        if let rawHooks = root["hooks"] {
            guard let dict = rawHooks as? [String: Any] else {
                throw HookInstallerError.invalidExistingJSON(path: config.cursorHooksPath)
            }
            hooks = dict
        } else {
            hooks = [:]
        }

        // Clean up any legacy `beforeShellExecution` entry installed by older Lumi versions
        if let rawOld = hooks["beforeShellExecution"] {
            guard let oldEntries = rawOld as? [[String: Any]] else {
                throw HookInstallerError.invalidExistingJSON(path: config.cursorHooksPath)
            }
            let cleanedOld = stripCursorLumiEntries(from: oldEntries)
            if cleanedOld.isEmpty { hooks.removeValue(forKey: "beforeShellExecution") } else { hooks["beforeShellExecution"] = cleanedOld }
        }

        for ev in events {
            var entries: [[String: Any]]
            if let rawEv = hooks[ev] {
                guard let arr = rawEv as? [[String: Any]] else {
                    throw HookInstallerError.invalidExistingJSON(path: config.cursorHooksPath)
                }
                entries = arr
            } else {
                entries = []
            }
            entries = stripCursorLumiEntries(from: entries)
            entries.append(["command": "\(cmd) \(ev)"])
            hooks[ev] = entries
        }
        root["hooks"] = hooks
        try writeJSON(root, to: config.cursorHooksPath)
    }

    private static func removeFromCursorHooks(at path: String) throws {
        guard var root = try readExistingJSONObject(at: path),
              var hooks = root["hooks"] as? [String: Any] else { return }
        for key in Array(hooks.keys) {
            if let entries = hooks[key] as? [[String: Any]] {
                let cleaned = stripCursorLumiEntries(from: entries)
                if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeJSON(root, to: path)
    }

    private static func stripCursorLumiEntries(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            if let cmd = entry["command"] as? String, isLumiCommand(cmd) {
                return nil
            }
            // Also clean up any legacy grouped entries installed by older versions of Lumi
            if let inner = entry["hooks"] as? [[String: Any]] {
                let kept = inner.filter { h in
                    let cmd = h["command"] as? String ?? ""
                    return !isLumiCommand(cmd)
                }
                if kept.isEmpty { return nil }
                var copy = entry
                copy["hooks"] = kept
                return copy
            }
            return entry
        }
    }

    // MARK: - OpenCode

    private static func installOpenCode(config: Config) throws {
        let spec = try spawnSpec(config: config)
        let fm = FileManager.default
        let dir = (config.openCodePluginPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Refuse to clobber a non-Lumi user plugin at the same path
        if fm.fileExists(atPath: config.openCodePluginPath),
           !isManagedOpenCodePlugin(at: config.openCodePluginPath) {
            throw HookInstallerError.foreignPluginFile(path: config.openCodePluginPath)
        }

        let execJS = jsStringLiteral(spec.executable)
        let baseArgsJS = spec.baseArgs.map(jsStringLiteral).joined(separator: ", ")
        let js = """
        // \(openCodeOwnershipMarker)
        // Lumi hook plugin for OpenCode — fire-and-forget session reporter
        import { spawn } from "node:child_process";

        const EXEC = \(execJS);
        const BASE_ARGS = [\(baseArgsJS)];
        function send(event, payload) {
          try {
            const p = spawn(EXEC, [...BASE_ARGS, "--agent", "opencode", event], { stdio: ["pipe", "ignore", "ignore"] });
            p.on("error", () => {});
            p.stdin.end(JSON.stringify(payload));
          } catch {}
        }

        export const LumiPlugin = async ({ directory }) => ({
          event: async ({ event }) => {
            const props = event?.properties || {};
            const sid = props.sessionID || props.sessionId || directory || "opencode";
            const type = event?.type || "";
            if (type === "session.busy") {
              send("session.busy", { session_id: sid, cwd: directory });
            } else if (type === "session.idle") {
              send("session.idle", { session_id: sid, cwd: directory });
            } else if (type === "session.status") {
              const st = String(props?.status?.type || "").toLowerCase();
              if (st === "busy" || st === "retry" || st === "idle") {
                send("session.status", { session_id: sid, cwd: directory, status: { type: st } });
              }
            } else if (type === "permission.asked") {
              send("permission.asked", { session_id: sid, cwd: directory });
            }
          }
        });
        """
        try js.write(toFile: config.openCodePluginPath, atomically: true, encoding: .utf8)
    }

    private static func uninstallOpenCode(config: Config) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.openCodePluginPath) else { return }
        guard isManagedOpenCodePlugin(at: config.openCodePluginPath) else {
            throw HookInstallerError.foreignPluginFile(path: config.openCodePluginPath)
        }
        try fm.removeItem(atPath: config.openCodePluginPath)
    }

    private static func isManagedOpenCodePlugin(at path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.contains(openCodeOwnershipMarker) || content.contains(legacyOpenCodeMarker)
    }

    private static func jsStringLiteral(_ raw: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let arrStr = String(data: data, encoding: .utf8),
              arrStr.count >= 2 else {
            return "\"\""
        }
        return String(arrStr.dropFirst().dropLast())
    }

    // MARK: - Generic Grouped JSON Hook Helpers

    private static func mergeIntoGroupedHooks(at path: String, events: [String], command: String, matcher: String?) throws {
        var root = try readExistingJSONObject(at: path) ?? [:]
        var hooks: [String: Any]
        if let rawHooks = root["hooks"] {
            guard let dict = rawHooks as? [String: Any] else {
                throw HookInstallerError.invalidExistingJSON(path: path)
            }
            hooks = dict
        } else {
            hooks = [:]
        }

        for ev in events {
            var groups: [[String: Any]]
            if let rawEv = hooks[ev] {
                guard let arr = rawEv as? [[String: Any]] else {
                    throw HookInstallerError.invalidExistingJSON(path: path)
                }
                groups = arr
            } else {
                groups = []
            }
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
        guard var root = try readExistingJSONObject(at: path),
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
                return !isLumiCommand(cmd)
            }
            if kept.isEmpty { return nil }
            var copy = group
            copy["hooks"] = kept
            return copy
        }
    }

    /// Matches ONLY Lumi's own hook commands (legacy `lumi-hook.py` or Lumi binary `--hook --agent ...`),
    /// never matching unrelated third-party tools that happen to use `--hook --agent`.
    static func isLumiCommand(_ command: String) -> Bool {
        if command.contains("lumi-hook.py") {
            return true
        }
        guard let flagRange = command.range(of: "--hook --agent ") else { return false }
        let prefix = command[..<flagRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return unquoted == "Lumi" || unquoted.hasSuffix("/Lumi")
    }

    private static func containsLumiCommand(at path: String) -> Bool {
        guard let str = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        if str.contains("lumi-hook.py") { return true }
        // Match lines/entries invoking Lumi executable with `--hook --agent`
        return str.contains("/Lumi\\\" --hook --agent ")
            || str.contains("/Lumi\" --hook --agent ")
            || str.contains("/Lumi --hook --agent ")
    }

    /// Strict RFC 8259 check rejecting JSONC comments (`//`, `/*`) and trailing commas (`,}` / `,]`)
    /// that Apple's Foundation `JSONSerialization` leniently accepts.
    static func isStrictStandardJSON(_ data: Data) -> Bool {
        let bytes = Array(data)
        let n = bytes.count
        var i = 0
        var inString = false
        var escaped = false
        var lastSignificant: UInt8 = 0

        while i < n {
            let b = bytes[i]
            if inString {
                if escaped {
                    escaped = false
                } else if b == 0x5C { // '\'
                    escaped = true
                } else if b == 0x22 { // '"'
                    inString = false
                    lastSignificant = 0x22
                }
                i += 1
                continue
            }

            // Skip JSON whitespace
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                i += 1
                continue
            }
            // Reject comments (`//` or `/*`) outside strings
            if b == 0x2F, i + 1 < n, (bytes[i + 1] == 0x2F || bytes[i + 1] == 0x2A) {
                return false
            }
            // Reject trailing commas before `}` or `]`
            if (b == 0x7D || b == 0x5D) && lastSignificant == 0x2C {
                return false
            }
            if b == 0x22 {
                inString = true
            } else {
                lastSignificant = b
            }
            i += 1
        }
        return !inString
    }

    /// Reads an existing JSON object strictly:
    /// - Returns `nil` ONLY when the file does not exist (safe to create fresh).
    /// - Throws `HookInstallerError.invalidExistingJSON` if the file exists but cannot be read/parsed
    ///   as strict standard RFC 8259 JSON (rejecting JSONC comments, trailing commas, syntax errors).
    private static func readExistingJSONObject(at path: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw HookInstallerError.invalidExistingJSON(path: path)
        }
        // Treat empty/whitespace-only files as empty object
        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return [:]
        }
        guard isStrictStandardJSON(data),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.invalidExistingJSON(path: path)
        }
        return parsed
    }

    private static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        if fm.fileExists(atPath: path) {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            var backup = "\(path).bak-\(fmt.string(from: Date()))"
            if fm.fileExists(atPath: backup) {
                backup += "-\(UUID().uuidString.prefix(6))"
            }
            do {
                try fm.copyItem(atPath: path, toPath: backup)
            } catch {
                throw HookInstallerError.backupFailed(path: path, reason: error.localizedDescription)
            }
            guard fm.fileExists(atPath: backup) else {
                throw HookInstallerError.backupFailed(path: path, reason: "Backup file missing after copy")
            }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
