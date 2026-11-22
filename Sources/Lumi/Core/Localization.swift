import Foundation

// MARK: - User Preferences Enums

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en     = "en"

    public var id: String { rawValue }

    public var resolvedIsEnglish: Bool {
        switch self {
        case .en:     return true
        case .zhHans: return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return !preferred.hasPrefix("zh")
        }
    }

    public func label(isEnglish: Bool) -> String {
        switch self {
        case .system: return isEnglish ? "Follow System" : "跟随系统"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }
}

public enum FloatingAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case charcoal = "charcoal"
    case oatLight = "oat_light"

    public var id: String { rawValue }

    public func label(isEnglish: Bool) -> String {
        switch self {
        case .charcoal: return isEnglish ? "Warm Charcoal" : "暖炭深色"
        case .oatLight: return isEnglish ? "Morning Oat Light" : "晨光燕麦浅色"
        }
    }
}

public enum GlobalHotKeyPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case off            = "off"
    case optionL        = "option_l"
    case controlOptionL = "control_option_l"
    case commandShiftL  = "command_shift_l"

    public var id: String { rawValue }

    public func label(isEnglish: Bool) -> String {
        switch self {
        case .off:            return isEnglish ? "Disabled" : "关闭"
        case .optionL:        return "⌥L"
        case .controlOptionL: return "⌃⌥L"
        case .commandShiftL:  return "⌘⇧L"
        }
    }
}

// MARK: - Instant Reactive Localization Table (Zero Restart Needed)

public struct L10n: Sendable {
    public let isEnglish: Bool

    public init(isEnglish: Bool) {
        self.isEnglish = isEnglish
    }

    // MARK: Tabs & Telemetry
    public var tabAll: String { isEnglish ? "All" : "全部" }
    public var tabRunning: String { isEnglish ? "Running" : "执行中" }
    public var tabUnread: String { isEnglish ? "Unread" : "待查看" }
    public var allAgents: String { isEnglish ? "All Agents" : "全平台" }
    public var markAllRead: String { isEnglish ? "Mark all read" : "全部已读" }

    // MARK: Mode & Controls
    public var desktopMode: String { isEnglish ? "Desktop" : "桌面模式" }
    public var dockToNotch: String { isEnglish ? "Notch" : "回到刘海" }
    public var helpDesktopMode: String { isEnglish ? "Detach into a draggable floating board" : "切换为可拖动的桌面悬浮看板" }
    public var helpDockToNotch: String { isEnglish ? "Dock back into the MacBook Dynamic Notch" : "收回 MacBook 刘海灵动岛" }
    public var helpPinnedOn: String { isEnglish ? "Pinned on top across all Spaces" : "已置顶（跨桌面跟随）" }
    public var helpPinnedOff: String { isEnglish ? "Pin window on top" : "置顶窗口" }
    public var helpSoundOn: String { isEnglish ? "Completion sound enabled" : "完成提示音已开" }
    public var helpSoundOff: String { isEnglish ? "Completion sound muted" : "完成提示音已关" }
    public var helpDndActive: String { isEnglish ? "Do Not Disturb active (click to resume)" : "勿扰模式开启中（点此恢复提醒）" }
    public var helpSwitchAppearance: String { isEnglish ? "Toggle Warm Charcoal / Morning Oat Light" : "切换暖炭深色 / 晨光燕麦浅色" }
    public var helpSettings: String { isEnglish ? "Open Lumi Settings" : "打开 Lumi 设置" }
    public var helpHide: String { isEnglish ? "Hide to menu bar" : "收起到菜单栏" }
    public var helpPokeMascot: String { isEnglish ? "Click to poke Lumi (4× for dizzy easter egg!)" : "点 Lumi 互动（连戳 4 下会晕哦）" }

    // MARK: Group Headers & Empty States
    public var groupNeedsInput: String { isEnglish ? "NEEDS YOUR INPUT · CLICK TO REPLY" : "等待审批或回复 · 点击立即处理" }
    public var groupRunning: String { isEnglish ? "RUNNING" : "正在执行" }
    public var groupUnread: String { isEnglish ? "UNREAD · CLICK TO JUMP & MARK READ" : "待查看 · 点击跳转即已读" }
    public var emptyRunning: String { isEnglish ? "No active conversations right now" : "当前没有正在执行的对话" }
    public var emptyUnread: String { isEnglish ? "No unread finished conversations" : "暂无未读的独立对话完成项" }
    public var emptyAll: String { isEnglish ? "All caught up — Lumi is taking a nap…" : "所有对话都已处理完毕，Lumi 正在打盹…" }
    public func recentlyRead(_ count: Int) -> String { isEnglish ? "Recently read (\(count))" : "最近已读 (\(count))" }

    // MARK: Row Labels & Tooltips
    public var openCTA: String { isEnglish ? "Open ↗" : "打开 ↗" }
    public var replyCTA: String { isEnglish ? "Reply ↗" : "去回复 ↗" }
    public var errorTag: String { isEnglish ? "· Failed" : "· 执行出错" }
    public var needsInputBadge: String { isEnglish ? "Needs approval" : "等待你的确认" }
    public var helpMarkReadOnly: String { isEnglish ? "Mark as read without switching" : "仅标为已读" }
    public func helpJumpUnread(_ app: String) -> String {
        isEnglish ? "Click to jump to \(app) and mark as read" : "单击切换到 \(app) 并移出待查看"
    }
    public func helpJump(_ app: String) -> String {
        isEnglish ? "Click to jump to \(app)" : "单击切换到 \(app)"
    }
    public func helpJumpNeedsInput(_ app: String) -> String {
        isEnglish ? "Click to switch to \(app) and respond" : "单击立即切回 \(app) 审批或回复"
    }

    // MARK: Mascot Captions & Compact Headline
    public func stageCaption(for mood: MascotMood) -> String {
        switch mood {
        case .dizzy:         return isEnglish ? "So dizzy @ @" : "转晕啦 @ @"
        case .poked:         return isEnglish ? "Hehe, watching~" : "嘿嘿在盯盘~"
        case .celebrating:   return isEnglish ? "Task finished!" : "有对话完工啦!"
        case .needsInput:    return isEnglish ? "Needs your reply!" : "等你审批/回复!"
        case .error:         return isEnglish ? "Run failed" : "发现执行出错"
        case .working:       return isEnglish ? "Lumi watching" : "Lumi 盯盘中"
        case .waitingUnread: return isEnglish ? "Ready to review" : "等你查看哟"
        case .sleeping:      return isEnglish ? "All idle · Zzz" : "全部空闲 · Zzz"
        }
    }

    public func mascotLongStatus(running: Int, unread: Int, needsInput: Int) -> String {
        if needsInput > 0 {
            return isEnglish
                ? "\(needsInput) conversation(s) waiting for your approval or reply!"
                : "有 \(needsInput) 个对话卡住等你审批或回复！"
        }
        if running > 0 && unread > 0 {
            return isEnglish
                ? "Watching \(running) active · \(unread) unread finished"
                : "正在盯盘 \(running) 个对话 · 另有 \(unread) 条已完工等你查看"
        }
        if running > 0 {
            return isEnglish
                ? "Watching \(running) active conversation(s)…"
                : "正在专注盯盘 \(running) 个对话…"
        }
        if unread > 0 {
            return isEnglish
                ? "\(unread) finished conversation(s) ready — click to jump!"
                : "有 \(unread) 个对话已完工，点卡片直达并自动已读！"
        }
        return isEnglish ? "All caught up — taking a nap (Zzz)" : "全部空闲，趴在刘海边打盹中 Zzz"
    }

    public func compactHeadline(running: Int, unread: Int, needsInput: Int) -> String {
        if needsInput > 0 {
            return isEnglish ? "\(needsInput) needs input" : "\(needsInput) 个对话等你确认"
        }
        if running > 0 && unread > 0 { return isEnglish ? "Running · Unread" : "执行中 · 待查看" }
        if running > 0 { return isEnglish ? "\(running) running" : "\(running) 个对话执行中" }
        if unread > 0 { return isEnglish ? "\(unread) unread" : "\(unread) 个对话待查看" }
        return isEnglish ? "Lumi watching" : "Lumi 盯盘中"
    }

    // MARK: Accessibility Hint
    public var grantAccessibility: String { isEnglish ? "Authorize" : "前往授权" }
    public var accessibilityHintBanner: String {
        isEnglish
            ? "Grant Accessibility in System Settings so Lumi can jump straight to the exact Antigravity chat."
            : "尚未授权「辅助功能」，Lumi 已帮你切到 Antigravity 窗口；点右侧前往授权，即可自动精准定位到具体对话。"
    }
    public var accessibilityStaleHintBanner: String {
        isEnglish
            ? "Accessibility permission looks stale after an update. Remove Lumi (-) and re-add /Applications/Lumi.app in System Settings."
            : "如果系统设置里 Lumi 的开关已是打开状态仍无反应，请先选中 Lumi 点左下角「-」删掉旧条目，再点「+」重新添加 /Applications/Lumi.app。"
    }

    // MARK: Menu Bar & Context Menu
    public func statusTooltip(running: Int, unread: Int, needsInput: Int, dndRemaining: String?) -> String {
        var base = isEnglish
            ? "Lumi — Running: \(running) · Unread: \(unread)"
            : "Lumi — 执行中: \(running) · 待查看: \(unread)"
        if needsInput > 0 {
            base += isEnglish ? " · Needs Input: \(needsInput)" : " · 待确认: \(needsInput)"
        }
        if let dndRemaining {
            base += isEnglish ? " · DND (\(dndRemaining))" : " · 勿扰中 (\(dndRemaining))"
        }
        base += isEnglish ? " (Left-click toggle, Right-click menu)" : "（左键展开/切换，右键菜单）"
        return base
    }

    public var menuSwitchToFloating: String { isEnglish ? "Switch to Floating Board" : "切换为桌面悬浮看板" }
    public var menuSwitchToNotch: String { isEnglish ? "Dock to Dynamic Notch" : "切换为刘海灵动岛" }
    public var menuSwitchToLight: String { isEnglish ? "Theme: Morning Oat Light" : "切换为晨光燕麦浅色" }
    public var menuSwitchToDark: String { isEnglish ? "Theme: Warm Charcoal Dark" : "切换为暖炭壁炉深色" }
    public var menuMarkAllRead: String { isEnglish ? "Mark All as Read" : "全部标为已读" }
    public var menuDNDTitle: String { isEnglish ? "Do Not Disturb" : "勿扰静音" }
    public var menuDND30m: String { isEnglish ? "Mute for 30 Minutes" : "静音 30 分钟" }
    public var menuDND1h: String { isEnglish ? "Mute for 1 Hour" : "静音 1 小时" }
    public var menuDNDOff: String { isEnglish ? "Resume Alerts" : "关闭勿扰" }
    public var menuLanguageTitle: String { isEnglish ? "Language" : "界面语言" }
    public var menuSettings: String { isEnglish ? "Settings…" : "设置…" }
    public var menuQuit: String { isEnglish ? "Quit Lumi" : "退出 Lumi" }

    // MARK: Notifications
    public var testNotifTitle: String { isEnglish ? "✅ [Lumi] Alert Test Passed" : "✅ [Lumi] 提醒测试成功" }
    public var testNotifSubtitle: String { isEnglish ? "This is how Lumi notifies you on finish" : "独立对话完成时会这样提醒你" }
    public var testNotifBody: String { isEnglish ? "Finished chats stay in Unread until you click to jump back." : "已完成项会常驻在待查看列表，点完跳过去会自动标为已读。" }
    public func finishNotifTitle(kind: AgentKind, project: String, isError: Bool) -> String {
        let icon = isError ? "❌" : "✅"
        let verb = isError ? (isEnglish ? "failed" : "出错") : (isEnglish ? "finished" : "已完成")
        return "\(icon) [\(kind.displayName)] \(project) \(verb)"
    }
    public func finishNotifBody(kind: AgentKind) -> String {
        isEnglish ? "Click to jump straight back to \(kind.displayName)" : "点击直接切换回 \(kind.displayName)"
    }
    public func needsInputNotifTitle(kind: AgentKind, project: String) -> String {
        isEnglish ? "⏳ [\(kind.displayName)] \(project) needs your input" : "⏳ [\(kind.displayName)] \(project) 等待你的审批/回复"
    }
    public func needsInputNotifBody(kind: AgentKind) -> String {
        isEnglish ? "Click to switch to \(kind.displayName) and respond" : "点击立即切回 \(kind.displayName) 处理"
    }

    // MARK: Settings View
    public var settingsWindowTitle: String { isEnglish ? "Lumi Settings" : "Lumi 设置" }
    public var settingsTabGeneral: String { isEnglish ? "General" : "通用与形态" }
    public var settingsTabMascot: String { isEnglish ? "Mascot" : "Lumi 萌宠" }
    public var settingsTabAgents: String { isEnglish ? "AI Agents" : "AI 工具接入" }
    public var settingsTabAlerts: String { isEnglish ? "Alerts & DND" : "通知与勿扰" }

    public var secDisplayMode: String { isEnglish ? "Display & Appearance" : "显示形态与外观" }
    public var lblPrimaryMode: String { isEnglish ? "Primary Mode" : "主界面模式" }
    public var lblHoverExpand: String { isEnglish ? "Expand notch automatically on hover" : "鼠标悬停刘海自动展开面板" }
    public var lblFullscreenHide: String { isEnglish ? "Skip auto-peek during fullscreen video/presentations" : "全屏看视频或演示时不自动弹出刘海" }
    public var lblTargetScreen: String { isEnglish ? "Notch Screen" : "灵动岛显示屏幕" }
    public var lblAutoScreen: String { isEnglish ? "Auto (Prefer MacBook Notch Display)" : "自动（优先 MacBook 刘海屏）" }
    public var lblAlwaysOnTop: String { isEnglish ? "Keep floating board on top across Spaces" : "悬浮看板始终置顶（跨桌面 Space 跟随）" }
    public var lblFloatingAppearance: String { isEnglish ? "Panel Theme" : "面板外观主题" }

    public var secBehavior: String { isEnglish ? "Language, Hotkey & Startup" : "语言、快捷键与启动" }
    public var lblLanguage: String { isEnglish ? "Interface Language" : "界面语言" }
    public var lblGlobalHotkey: String { isEnglish ? "Global Toggle Hotkey" : "全局唤出/收起快捷键" }
    public var lblHideCLI: String { isEnglish ? "Hide headless CLI batch runs (desktop chats only)" : "隐藏后台 CLI 批处理任务（只看独立桌面对话）" }
    public var lblLaunchAtLogin: String { isEnglish ? "Launch Lumi at macOS login" : "登录 macOS 时自动启动 Lumi" }

    public var secAbout: String { isEnglish ? "About & Updates" : "开源项目与版本更新" }
    public var lblLocalOnly: String { isEnglish ? "100% Local · Zero Telemetry" : "100% 本地运行 · 零云端上传" }
    public var btnCheckUpdates: String { isEnglish ? "Check for Updates" : "检查新版本" }
    public var btnCheckingUpdates: String { isEnglish ? "Checking…" : "正在检查…" }
    public var btnDownloadUpdate: String { isEnglish ? "Open Release" : "前往下载" }
    public func updateUpToDate(_ ver: String) -> String { isEnglish ? "Up to date (v\(ver))" : "已是最新版本 (v\(ver))" }
    public func updateAvailable(_ tag: String) -> String { isEnglish ? "New version \(tag) available!" : "发现新版本 \(tag)！" }
    public var updateCheckFailed: String { isEnglish ? "Could not reach GitHub Releases" : "无法连接 GitHub Releases，请稍后再试" }

    public var mascotGreeting: String { isEnglish ? "Hi, I'm Lumi Ember!" : "你好，我是 Lumi Ember！" }
    public var mascotPokeTip: String { isEnglish ? "Tip: Click to poke me — 4 quick taps triggers dizzy mode!" : "提示：直接点我试试互动，连续戳 4 下我会转晕哦" }
    public var mascotPaletteTitle: String { isEnglish ? "Color Theme" : "外观配色" }

    public var agentsHeaderTitle: String { isEnglish ? "One-Click AI Agent Integration" : "一键接入 AI 编程工具" }
    public var agentsHeaderDesc: String {
        isEnglish
            ? "Antigravity, Codex, and Claude Code work zero-config out of the box. Install Hooks for live tool actions, approval alerts, and extra agents (original configs are backed up automatically)."
            : "Antigravity、Codex、Claude Code 开箱自动读取本地会话；安装 Hook 后可实时精准显示当前工具动作与审批提醒（自动备份原配置）。"
    }
    public var btnRefreshStatus: String { isEnglish ? "Refresh" : "刷新状态" }
    public var axBannerTitle: String { isEnglish ? "Antigravity Exact-Conversation Click-to-Jump" : "Antigravity 点击卡片精准直达具体对话" }
    public var axReady: String { isEnglish ? "Ready" : "已就绪" }
    public var axNeeded: String { isEnglish ? "Accessibility Needed" : "需辅助功能权限" }
    public var axDescReady: String {
        isEnglish
            ? "Codex uses native codex:// deep links; Antigravity uses official Cmd+K palette jump (clipboard-safe)."
            : "Codex 已原生支持深链直达；Antigravity 授权辅助功能后，Lumi 会自动用官方 Cmd+K 精准切到对应对话（不破坏剪贴板）。"
    }
    public var axDescNeeded: String {
        isEnglish
            ? "If toggle looks ON in System Settings after an update, remove Lumi (-) and re-add /Applications/Lumi.app."
            : "若系统设置里开关已开但仍显示未就绪：选中列表中的 Lumi 点左下角「-」删掉旧条目，再点「+」重新添加 /Applications/Lumi.app。"
    }
    public var hookActive: String { isEnglish ? "Hook Active" : "Hook 已接入" }
    public var autoWatchReady: String { isEnglish ? "Auto-Watch Ready" : "自动监测已就绪" }
    public var btnInstallHook: String { isEnglish ? "Install" : "一键安装" }
    public var btnUninstallHook: String { isEnglish ? "Uninstall" : "卸载 Hook" }
    public func hookFail(_ app: String, _ err: String) -> String { isEnglish ? "❌ \(app) failed: \(err)" : "❌ \(app) 操作失败：\(err)" }
    public func hookInstalledMsg(_ app: String) -> String { isEnglish ? "✅ Installed \(app) Hook (backup saved)" : "✅ 已成功接入 \(app) Hook（原配置已自动备份）" }
    public func hookRemovedMsg(_ app: String) -> String { isEnglish ? "Removed \(app) Lumi Hook" : "已移除 \(app) 的 Lumi Hook" }

    public var secCompletionAlerts: String { isEnglish ? "Completion & Approval Alerts" : "完成与审批提醒" }
    public var lblPlaySound: String { isEnglish ? "Play sound on completion / approval request" : "任务完工或需要审批时播放提示音" }
    public var lblSoundTone: String { isEnglish ? "Alert Sound" : "提示音色" }
    public var lblSystemNotif: String { isEnglish ? "Send macOS notifications (click to jump & mark read)" : "发送 macOS 系统通知（点击通知直接切回对应 App 并自动已读）" }
    public var secDND: String { isEnglish ? "Do Not Disturb (Quick Mute)" : "勿扰模式（开会一键静音）" }
    public var dndInactiveLabel: String { isEnglish ? "Alerts active — mute temporarily during meetings" : "提醒正常开启中 · 开会或专注时可临时一键静音" }
    public func dndActiveLabel(_ rem: String) -> String { isEnglish ? "Muted for \(rem) (sounds, banners & auto-peek paused)" : "勿扰静音中（剩余 \(rem)，已暂停音效、通知与自动弹出）" }
    public var secTest: String { isEnglish ? "Test" : "测试" }
    public var btnTestAlert: String { isEnglish ? "Send Test Alert & Sound" : "发送测试通知与提示音" }
    public var testAlertTip: String { isEnglish ? "Set Lumi to Alerts in System Settings → Notifications for persistent banners" : "可在 macOS 系统设置 → 通知 → Lumi 设为「提醒」样式" }

    // MARK: Dynamic Action Localization (Translates Hook/Scanner Chinese Actions On-The-Fly)
    public func action(_ raw: String) -> String {
        guard isEnglish else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let exact: [String: String] = [
            "思考规划中…": "Planning…",
            "深度思考中…": "Deep reasoning…",
            "思考与执行中…": "Thinking & running…",
            "整理结果中…": "Processing result…",
            "整理工具结果…": "Processing tool output…",
            "输出回复中…": "Writing response…",
            "收尾确认中…": "Settling…",
            "后台任务运行中…": "Background task running…",
            "等待后台任务/子 Agent 完成…": "Waiting for subagents…",
            "执行中…": "Running…",
            "执行工具中…": "Running tool…",
            "已完成": "Completed",
            "执行出错": "Execution failed",
            "已手动停止": "Stopped by user",
            "等待你确认/回答": "Waiting for your reply",
            "等待你的审批或回复": "Waiting for approval",
            "等待审批": "Waiting for approval",
            "读取文件": "Reading file",
            "修改文件": "Editing file",
            "修改代码文件": "Editing source file",
            "查看文件/图片": "Inspecting file",
            "应用代码补丁": "Applying patch",
            "运行终端命令": "Running shell command",
            "运行脚本/命令": "Running command",
            "运行并行检查": "Running parallel checks",
            "联网搜索": "Searching the web",
            "检索代码": "Searching codebase",
            "派发子 Agent": "Launching subagent",
            "操作浏览器": "Controlling browser",
            "更新执行计划": "Updating plan",
            "全局": "Global"
        ]
        if let hit = exact[trimmed] { return hit }

        let prefixes: [(String, String)] = [
            ("子任务 · ", "Subagent · "),
            ("编辑 ", "Editing "),
            ("批量编辑 ", "Batch editing "),
            ("读取 ", "Reading "),
            ("执行 · ", "Running · "),
            ("运行 · ", "Running · "),
            ("运行 ", "Running "),
            ("并行检查 · ", "Checking · "),
            ("联网搜索 · ", "Web search · "),
            ("检索 · ", "Searching · "),
            ("派发子 Agent · ", "Subagent · "),
            ("执行出错 · ", "Failed · "),
            ("等待确认 · ", "Approve · "),
            ("调用 ", "Calling ")
        ]
        for (zh, en) in prefixes {
            if trimmed.hasPrefix(zh) {
                var rest = String(trimmed.dropFirst(zh.count))
                rest = rest.replacingOccurrences(of: " 个文件", with: " files")
                rest = rest.replacingOccurrences(of: " 等 ", with: " + ")
                return en + rest
            }
        }
        if trimmed.hasPrefix("等待 ") && trimmed.hasSuffix(" 个子 Agent 执行…") {
            let mid = trimmed.dropFirst("等待 ".count).dropLast(" 个子 Agent 执行…".count)
            return "Waiting on \(mid) subagent(s)…"
        }
        return trimmed
    }

    public func project(_ raw: String) -> String {
        if isEnglish && raw == "全局" { return "Global" }
        return raw
    }
}
