import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @State private var selectedTab = 0
    @State private var hookMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label("通用与形态", systemImage: "macbook") }
                    .tag(0)

                mascotTab
                    .tabItem { Label("Lumi 萌宠", systemImage: "sparkles") }
                    .tag(1)

                agentsTab
                    .tabItem { Label("AI 工具接入", systemImage: "cpu") }
                    .tag(2)

                alertsTab
                    .tabItem { Label("通知与音效", systemImage: "bell.badge") }
                    .tag(3)
            }
            .padding(.top, 6)

            Divider()

            HStack {
                Text("Lumi v1.0.0 · MIT License")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出 Lumi", systemImage: "power")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 516)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("显示形态") {
                Picker("主界面模式", selection: $store.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if store.displayMode == .notch {
                    Toggle("鼠标悬停刘海自动展开面板", isOn: $store.hoverToExpand)
                    Picker("灵动岛显示屏幕", selection: $store.selectedScreenName) {
                        Text("自动（优先 MacBook 刘海屏）").tag("auto")
                        ForEach(NSScreen.screens, id: \.localizedName) { screen in
                            Text(screen.localizedName).tag(screen.localizedName)
                        }
                    }
                } else {
                    Toggle("悬浮看板始终置顶（跨桌面 Space 跟随）", isOn: $store.alwaysOnTop)
                }
            }

            Section("会话过滤与启动") {
                Toggle("隐藏后台 CLI 批处理任务（只看独立桌面对话）", isOn: $store.hideCLISessions)
                Toggle("登录 macOS 时自动启动 Lumi", isOn: $store.launchAtLogin)
            }

            Section("开源项目信息") {
                HStack {
                    Text("Lumi v1.0.0 · MIT License")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("100% 本地运行 · 零云端上传")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    // MARK: - Mascot

    private var mascotTab: some View {
        VStack(spacing: 18) {
            // Interactive Hero Preview
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.88))
                    .frame(height: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(store.mascotTheme.bodyTop.opacity(0.35), lineWidth: 1)
                    )

                HStack(spacing: 22) {
                    LumiMascotView(
                        mood: store.mascotMood,
                        theme: store.mascotTheme,
                        size: 92,
                        isCompact: false,
                        isActiveSurface: true,
                        onPoke: { store.pokeMascot() }
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("你好，我是 Lumi！")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(store.mascotStatusText)
                            .font(.system(size: 12.5))
                            .foregroundColor(.white.opacity(0.72))
                        Text("提示：直接点我试试互动，连续戳 4 下我会转晕哦")
                            .font(.system(size: 11))
                            .foregroundColor(store.mascotTheme.eyeGlow.opacity(0.85))
                    }
                }
                .padding(.horizontal, 24)
            }

            // Theme Picker Grid
            VStack(alignment: .leading, spacing: 10) {
                Text("外观配色")
                    .font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(MascotTheme.allCases) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.mascotTheme = theme
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(LinearGradient(colors: [theme.bodyTop, theme.bodyBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                Text(theme.displayName)
                                    .font(.system(size: 12, weight: store.mascotTheme == theme ? .semibold : .regular))
                                Spacer()
                                if store.mascotTheme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(store.mascotTheme == theme ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(store.mascotTheme == theme ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Agents & Hook Installer

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("一键接入 AI 编程工具")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("Antigravity、Codex、Claude Code 开箱自动读取本地会话；安装 Hook 后可实时精准显示当前正在执行的工具动作（自动备份原配置）。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("刷新状态") {
                    store.refreshHookStatus()
                    store.refreshAccessibilityStatus()
                }
                    .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if let msg = hookMessage {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 18)
            }

            // Antigravity Exact-Conversation Jump Banner
            HStack(spacing: 12) {
                Image(systemName: store.accessibilityGranted ? "checkmark.seal.fill" : "hand.tap.fill")
                    .font(.system(size: 16))
                    .foregroundColor(store.accessibilityGranted ? Color(red: 0.22, green: 0.84, blue: 0.54) : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Antigravity 点击卡片精准直达具体对话")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(store.accessibilityGranted ? "已就绪" : "需辅助功能权限")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(store.accessibilityGranted ? Color(red: 0.20, green: 0.80, blue: 0.50) : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill((store.accessibilityGranted ? Color.green : Color.orange).opacity(0.15)))
                    }
                    Text(store.accessibilityGranted
                         ? "Codex 已原生支持深链直达；Antigravity 授权辅助功能后，Lumi 会自动用官方 Cmd+K 精准切到对应对话（不破坏剪贴板）。"
                         : "若系统设置里开关已开但仍显示未就绪：选中列表中的 Lumi 点左下角「-」删掉旧条目，再点「+」重新添加 /Applications/Lumi.app。")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if store.accessibilityGranted {
                    Toggle("", isOn: $store.autoJumpAntigravity)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                } else {
                    Button("前往授权") {
                        store.requestAccessibilityPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 18)
            .onAppear { store.refreshAccessibilityStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.refreshAccessibilityStatus()
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AgentKind.allCases) { kind in
                        let installed = store.hookStatus[kind] ?? false
                        HStack(spacing: 12) {
                            Text(kind.shortLabel)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(kind.accentColor)
                                .frame(width: 66, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(kind.accentColor.opacity(0.16)))

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(kind.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    if installed {
                                        Text("Hook 已接入")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Color(red: 0.18, green: 0.78, blue: 0.48))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.green.opacity(0.15)))
                                    } else if kind == .antigravity || kind == .codex || kind == .claude {
                                        Text("自动监测已就绪")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                                    }
                                }
                                Text(kind.hookDescription)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button(installed ? "卸载 Hook" : "一键安装") {
                                if let err = store.toggleHook(for: kind) {
                                    hookMessage = "❌ \(kind.displayName) 操作失败：\(err)"
                                } else {
                                    let nowOn = store.hookStatus[kind] ?? false
                                    hookMessage = nowOn
                                        ? "✅ 已成功接入 \(kind.displayName) Hook（原配置已自动备份）"
                                        : "已移除 \(kind.displayName) 的 Lumi Hook"
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(installed ? .secondary : .accentColor)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Alerts & Sounds

    private var alertsTab: some View {
        Form {
            Section("独立对话完成提醒") {
                Toggle("任务完成时播放提示音", isOn: $store.soundEnabled)
                Picker("提示音色", selection: $store.selectedSound) {
                    ForEach(MonitorStore.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: store.selectedSound) { _, newValue in
                    store.playSound(newValue)
                }

                Toggle("发送 macOS 系统通知（点击通知直接切回对应 App 并自动已读）", isOn: $store.notificationsEnabled)
            }

            Section("测试") {
                HStack {
                    Button("发送测试通知与提示音") {
                        store.sendTestNotification()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Text("可在 macOS 系统设置 → 通知 → Lumi 设为「提醒」样式")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}
