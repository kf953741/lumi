import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @State private var selectedTab = 0
    @State private var hookMessage: String? = nil
    @State private var checkingUpdate = false
    @State private var updateResult: UpdateCheckResult? = nil

    private var t: L10n { store.l10n }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label(t.settingsTabGeneral, systemImage: "macbook") }
                    .tag(0)

                mascotTab
                    .tabItem { Label(t.settingsTabMascot, systemImage: "sparkles") }
                    .tag(1)

                agentsTab
                    .tabItem { Label(t.settingsTabAgents, systemImage: "cpu") }
                    .tag(2)

                alertsTab
                    .tabItem { Label(t.settingsTabAlerts, systemImage: "bell.badge") }
                    .tag(3)
            }
            .padding(.top, 6)

            Divider()

            HStack {
                Text("Lumi v\(UpdateChecker.currentAppVersion) · MIT License")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label(t.menuQuit, systemImage: "power")
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
        .frame(width: 580, height: 572)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(t.secDisplayMode) {
                Picker(t.lblPrimaryMode, selection: $store.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.label(isEnglish: store.isEnglish)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker(t.lblFloatingAppearance, selection: $store.floatingAppearance) {
                    ForEach(FloatingAppearance.allCases) { style in
                        Text(style.label(isEnglish: store.isEnglish)).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if store.displayMode == .notch {
                    Toggle(t.lblHoverExpand, isOn: $store.hoverToExpand)
                    Toggle(t.lblFullscreenHide, isOn: $store.hideAutoPeekInFullscreen)
                    Picker(t.lblTargetScreen, selection: $store.selectedScreenName) {
                        Text(t.lblAutoScreen).tag("auto")
                        ForEach(NSScreen.screens, id: \.localizedName) { screen in
                            Text(screen.localizedName).tag(screen.localizedName)
                        }
                    }
                } else {
                    Toggle(t.lblAlwaysOnTop, isOn: $store.alwaysOnTop)
                }
            }

            Section(t.secBehavior) {
                Picker(t.lblLanguage, selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.label(isEnglish: store.isEnglish)).tag(lang)
                    }
                }
                .pickerStyle(.segmented)

                Picker(t.lblGlobalHotkey, selection: $store.hotKeyPreset) {
                    ForEach(GlobalHotKeyPreset.allCases) { preset in
                        Text(preset.label(isEnglish: store.isEnglish)).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(t.lblHideCLI, isOn: $store.hideCLISessions)
                Toggle(t.lblLaunchAtLogin, isOn: $store.launchAtLogin)
            }

            Section(t.secAbout) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lumi v\(UpdateChecker.currentAppVersion) · MIT License")
                            .font(.system(size: 12, weight: .medium))
                        Text(t.lblLocalOnly)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    if checkingUpdate {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(t.btnCheckingUpdates).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    } else if case let .updateAvailable(tag, url) = updateResult {
                        HStack(spacing: 8) {
                            Text(t.updateAvailable(tag))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(LumiPalette.emberOrange)
                            Button(t.btnDownloadUpdate) {
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 8) {
                            if case let .upToDate(ver) = updateResult {
                                Text(t.updateUpToDate(ver))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else if case .failed = updateResult {
                                Text(t.updateCheckFailed)
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            Button(t.btnCheckUpdates) {
                                checkingUpdate = true
                                Task {
                                    let res = await UpdateChecker.checkLatest()
                                    await MainActor.run {
                                        checkingUpdate = false
                                        updateResult = res
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }

    // MARK: - Mascot

    private var mascotTab: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [LumiPalette.stageTop, LumiPalette.stageBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 150)
                    .overlay(
                        RadialGradient(
                            colors: [store.mascotTheme.bodyTop.opacity(0.24), Color.clear],
                            center: UnitPoint(x: 0.22, y: 0.50),
                            startRadius: 8,
                            endRadius: 120
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(store.mascotTheme.bodyTop.opacity(0.32), lineWidth: 1)
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
                        Text(t.mascotGreeting)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(LumiPalette.warmPrimary)
                        Text(store.mascotStatusText)
                            .font(.system(size: 12.5))
                            .foregroundColor(LumiPalette.warmSecondary)
                        Text(t.mascotPokeTip)
                            .font(.system(size: 11))
                            .foregroundColor(store.mascotTheme.eyeGlow.opacity(0.90))
                    }
                }
                .padding(.horizontal, 24)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(t.mascotPaletteTitle)
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
                                Text(theme.localizedName(isEnglish: store.isEnglish))
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
                    Text(t.agentsHeaderTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(t.agentsHeaderDesc)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(t.btnRefreshStatus) {
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

            HStack(spacing: 12) {
                Image(systemName: store.accessibilityGranted ? "checkmark.seal.fill" : "hand.tap.fill")
                    .font(.system(size: 16))
                    .foregroundColor(store.accessibilityGranted ? Color(red: 0.22, green: 0.84, blue: 0.54) : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.axBannerTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(store.accessibilityGranted ? t.axReady : t.axNeeded)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(store.accessibilityGranted ? Color(red: 0.20, green: 0.80, blue: 0.50) : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill((store.accessibilityGranted ? Color.green : Color.orange).opacity(0.15)))
                    }
                    Text(store.accessibilityGranted ? t.axDescReady : t.axDescNeeded)
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
                    Button(t.grantAccessibility) {
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
                            NativeAgentIconView(kind: kind, visualSize: 30)
                                .frame(width: 34, height: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(kind.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    if kind == .t3code {
                                        Text(installed ? t.autoWatchReady : (store.isEnglish ? "Auto-Detect" : "自动检测"))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(installed ? Color(red: 0.18, green: 0.78, blue: 0.48) : .secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(installed ? Color.green.opacity(0.15) : Color.primary.opacity(0.07)))
                                    } else if installed {
                                        Text(t.hookActive)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Color(red: 0.18, green: 0.78, blue: 0.48))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.green.opacity(0.15)))
                                    } else if kind == .antigravity || kind == .codex || kind == .claude {
                                        Text(t.autoWatchReady)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                                    }
                                }
                                Text(kind.hookDescription(isEnglish: store.isEnglish))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if kind == .t3code {
                                Text(store.isEnglish ? "Zero-Config" : "免配置")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                            } else {
                                Button(installed ? t.btnUninstallHook : t.btnInstallHook) {
                                    if let err = store.toggleHook(for: kind) {
                                        hookMessage = t.hookFail(kind.displayName, err)
                                    } else {
                                        let nowOn = store.hookStatus[kind] ?? false
                                        hookMessage = nowOn
                                            ? t.hookInstalledMsg(kind.displayName)
                                            : t.hookRemovedMsg(kind.displayName)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(installed ? .secondary : .accentColor)
                                .controlSize(.small)
                            }
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

    // MARK: - Alerts & Do Not Disturb

    private var alertsTab: some View {
        Form {
            Section(t.secCompletionAlerts) {
                Toggle(t.lblPlaySound, isOn: $store.soundEnabled)
                Picker(t.lblSoundTone, selection: $store.selectedSound) {
                    ForEach(MonitorStore.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: store.selectedSound) { _, newValue in
                    store.playSound(newValue)
                }

                Toggle(t.lblSystemNotif, isOn: $store.notificationsEnabled)
            }

            Section(t.secDND) {
                HStack(spacing: 10) {
                    Image(systemName: store.isDNDActive ? "moon.zzz.fill" : "bell.fill")
                        .foregroundColor(store.isDNDActive ? LumiPalette.emberOrange : .secondary)
                    Text(store.dndRemainingText.map { t.dndActiveLabel($0) } ?? t.dndInactiveLabel)
                        .font(.system(size: 11.5))
                        .foregroundColor(store.isDNDActive ? .primary : .secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(t.menuDND30m) { store.enableDND(minutes: 30) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(t.menuDND1h) { store.enableDND(minutes: 60) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if store.isDNDActive {
                        Button(t.menuDNDOff) { store.disableDND() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }

            Section(t.secTest) {
                HStack {
                    Button(t.btnTestAlert) {
                        store.sendTestNotification()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Text(t.testAlertTip)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}
