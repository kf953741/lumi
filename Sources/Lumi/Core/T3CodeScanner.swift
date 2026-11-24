import AppKit
import Foundation

struct T3PendingMatch: Equatable, Sendable {
    let providerKey: String
    let normalizedCwd: String
    let startedAt: Date
}

struct T3CodeScanResult: Sendable {
    let sessions: [AgentSession]
    /// Exact `"<provider>:<nativeId>"` keys of underlying provider sessions owned by T3 Code runs.
    let ownedNativeSessionIds: Set<String>
    /// Active T3 Code runs whose `nativeThreadRef` has not yet been written (first-second race window).
    let pendingMatches: [T3PendingMatch]
    /// Earliest timestamp when a grace-held run must be re-evaluated even if SQLite/WAL fingerprint did not change.
    let nextRevalidateAt: Date?
    /// True when T3 Code's own `statev2.sqlite` / `state.sqlite` failed transiently; callers must pause ALL `.t3code` completion confirmations.
    let deferAllCompletions: Bool
    /// Specific `"t3code:<threadId>"` IDs whose secondary ACP verification failed transiently; callers pause ONLY these sessions.
    let deferredSessionIds: Set<String>

    var hadTransientFailure: Bool {
        deferAllCompletions || !deferredSessionIds.isEmpty
    }

    init(
        sessions: [AgentSession],
        ownedNativeSessionIds: Set<String>,
        pendingMatches: [T3PendingMatch],
        nextRevalidateAt: Date? = nil,
        deferAllCompletions: Bool = false,
        deferredSessionIds: Set<String> = []
    ) {
        self.sessions = sessions
        self.ownedNativeSessionIds = ownedNativeSessionIds
        self.pendingMatches = pendingMatches
        self.nextRevalidateAt = nextRevalidateAt
        self.deferAllCompletions = deferAllCompletions
        self.deferredSessionIds = deferredSessionIds
    }

    func ownsUnderlying(_ session: AgentSession, now: Date = Date()) -> Bool {
        guard session.kind != .t3code else { return false }
        if ownedNativeSessionIds.contains(session.id) {
            return true
        }
        let canonical = "\(session.kind.rawValue):\(session.rawId)"
        if ownedNativeSessionIds.contains(canonical) {
            return true
        }
        let normCwd = T3CodeScanner.normalizePath(session.cwd)
        // Only suppress T3 scratch/worktree paths when T3 actually produced visible sessions,
        // so a failed/empty T3 scan can never hide the user's only visible copy of a session.
        if !sessions.isEmpty,
           (normCwd.contains("/.t3/scratch")
            || normCwd.contains("/.t3/worktrees")
            || normCwd.contains("/.t3/userdata")) {
            return true
        }
        if !pendingMatches.isEmpty, !normCwd.isEmpty {
            let refTime = session.startedAt ?? session.updatedAt
            for pm in pendingMatches where pm.providerKey == session.kind.rawValue && pm.normalizedCwd == normCwd {
                // Pending match expires 30s after launch so stale matches never suppress later standalone runs
                guard abs(now.timeIntervalSince(pm.startedAt)) <= 30 else { continue }
                if abs(refTime.timeIntervalSince(pm.startedAt)) <= 20 {
                    return true
                }
            }
        }
        return false
    }
}

/// Zero-config live monitor for T3 Code (Desktop & CLI) reading its local SQLite WAL control plane:
/// - Orchestration v2 (T3 Code v0.1.7+): `~/.t3/userdata/statev2.sqlite`
/// - Legacy v1 fallback: `~/.t3/userdata/state.sqlite`
final class T3CodeScanner: @unchecked Sendable {
    private let v2DbPath: String
    private let v1DbPath: String
    private let environmentIdPath: String
    private let antigravityProvidersRoot: String
    private let handoffGraceSeconds: TimeInterval
    private let acpIdleSeamSeconds: TimeInterval
    private let launchTime: Date
    private let isT3RunningCheck: @Sendable () -> Bool

    private let cacheLock = NSLock()
    private var lastT3Fingerprint: T3DBFingerprint?
    private var lastACPFingerprint: ACPSummaryFingerprint?
    private var lastT3ScanAt: Date = .distantPast
    private var lastScanLookback: Double = 0
    private var lastScanHadActive: Bool = false
    private var nextRevalidateAt: Date?
    private var lastACPActiveByThread: [String: (runId: String, seenAt: Date, latestActivity: Date, idleObservedAt: Date?)] = [:]
    private var lastACPFinishedByThread: [String: (runId: String, finishedAt: Date)] = [:]
    private var dirtyACPSummaryPaths: Set<String> = []
    private var cachedV2Snapshot: V2TransactionSnapshot?
    private var cachedV1Sessions: [AgentSession] = []
    private var cachedScanResult: T3CodeScanResult?
    private var terminalRunDetailCache: [String: V2RunDetail] = [:]
    private var antigravityBrainDirsCache: (dirs: [String], loadedAt: Date)?
    private var antigravitySummaryDBPathsCache: (paths: [String], loadedAt: Date)?
    private var cachedACPSummaryRowsByPath: [String: (stamp: ACPFileStampEntry, rows: [ACPConversationSummaryRow], parentTable: [String: String])] = [:]
    private var handoffVerificationCache: [String: Bool] = [:]

    private struct T3DBFingerprint: Equatable {
        let v2: FileStamp
        let v2Wal: FileStamp
        let v1: FileStamp
        let v1Wal: FileStamp
        let appRunning: Bool
    }

    private struct ACPFileStampEntry: Equatable {
        let path: String
        let db: FileStamp
        let wal: FileStamp
    }

    private struct ACPSummaryFingerprint: Equatable {
        let entries: [ACPFileStampEntry]
    }

    private struct ACPConversationSummaryRow: Sendable {
        let id: String
        let parentId: String
        let status: String
        let notFullyIdle: Bool
        let killed: Bool
        let lastModified: Date?
    }

    private struct ACPRootActiveState: Sendable {
        var parentRunning: Bool = false
        var parentNotFullyIdle: Bool = false
        var needsUserInput: Bool = false
        var activeChildCount: Int = 0
        var latestActivity: Date = .distantPast
        var earliestStaleExpiry: Date? = nil
    }

    private struct ACPLiveSnapshot: Sendable {
        let rowsById: [String: ACPConversationSummaryRow]
        let activeByRootId: [String: ACPRootActiveState]
        let latestModifiedByRootId: [String: Date]
        let expiredActiveRootIds: Set<String>
        let hadReadFailure: Bool
    }

    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int

        static func read(_ path: String) -> FileStamp {
            var st = stat()
            guard stat(path, &st) == 0 else {
                return FileStamp(inode: 0, size: -1, mtimeSec: 0, mtimeNsec: 0)
            }
            return FileStamp(
                inode: UInt64(st.st_ino),
                size: st.st_size,
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec
            )
        }
    }

    private static let pathSegmentAllowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    private static func defaultUserDataDir() -> String {
        if let envHome = ProcessInfo.processInfo.environment["T3CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envHome.isEmpty {
            let expanded = (envHome as NSString).expandingTildeInPath
            return "\(expanded)/userdata"
        }
        return "\(NSHomeDirectory())/.t3/userdata"
    }

    init(
        v2DbPath: String? = nil,
        v1DbPath: String? = nil,
        environmentIdPath: String? = nil,
        antigravityProvidersRoot: String? = nil,
        handoffGraceSeconds: TimeInterval = 150.0,
        acpIdleSeamSeconds: TimeInterval = 12.0,
        launchTime: Date = Date(),
        isT3RunningCheck: (@Sendable () -> Bool)? = nil
    ) {
        let userData = Self.defaultUserDataDir()
        let resolvedV2 = v2DbPath ?? "\(userData)/statev2.sqlite"
        let baseDir = URL(fileURLWithPath: resolvedV2).deletingLastPathComponent().path
        self.v2DbPath = resolvedV2
        self.v1DbPath = v1DbPath ?? "\(userData)/state.sqlite"
        self.environmentIdPath = environmentIdPath ?? URL(fileURLWithPath: resolvedV2)
            .deletingLastPathComponent()
            .appendingPathComponent("environment-id")
            .path
        self.antigravityProvidersRoot = antigravityProvidersRoot ?? "\(baseDir)/providers/antigravity"
        self.handoffGraceSeconds = max(0, handoffGraceSeconds)
        self.acpIdleSeamSeconds = max(0, acpIdleSeamSeconds)
        self.launchTime = launchTime
        self.isT3RunningCheck = isT3RunningCheck ?? {
            Self.isT3CodeAppRunning()
        }
    }

    func readEnvironmentId() -> String? {
        guard let raw = try? String(contentsOfFile: environmentIdPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds T3 Code's official `t3code://threads/<environmentId>/<encodedThreadId>` deep link
    /// (parsed by T3 Code's `promptLinkAppPath` -> `DesktopWebLinks.receive` -> `/$environmentId/$threadId`).
    static func deepLinkURL(environmentId: String, threadId: String, scheme: String = "t3code") -> URL? {
        let env = environmentId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tid = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !env.isEmpty, !tid.isEmpty,
              let encodedEnv = env.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters),
              let encodedTid = tid.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters) else {
            return nil
        }
        return URL(string: "\(scheme)://threads/\(encodedEnv)/\(encodedTid)")
    }

    func deepLinkURL(forThreadId threadId: String, scheme: String? = nil) -> URL? {
        guard let envId = readEnvironmentId() else { return nil }
        let resolvedScheme = scheme ?? Self.preferredURLScheme()
        return Self.deepLinkURL(environmentId: envId, threadId: threadId, scheme: resolvedScheme)
    }

    private static func preferredURLScheme() -> String {
        let prodRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code").isEmpty
        if prodRunning { return "t3code" }
        let devRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.t3tools.t3code.dev").isEmpty
        if devRunning { return "t3code-dev" }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") != nil {
            return "t3code"
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code.dev") != nil {
            return "t3code-dev"
        }
        return "t3code"
    }

    func scan(lookbackHours: Double = 24, now: Date = Date()) -> [AgentSession] {
        scanDetailed(lookbackHours: lookbackHours, now: now, forceFresh: false).sessions
    }

    /// Scans T3 Code's SQLite control plane plus live Antigravity ACP summary DBs.
    /// Pass `forceFresh: true` while `MonitorStore` has settling `t3code:` completion candidates
    /// so every pre-popup confirmation re-reads the latest committed WAL snapshots on both sides.
    func scanDetailed(lookbackHours: Double = 24, now: Date = Date(), forceFresh: Bool = false) -> T3CodeScanResult {
        let appRunning = isT3RunningCheck()
        let t3Fp = T3DBFingerprint(
            v2: FileStamp.read(v2DbPath),
            v2Wal: FileStamp.read(v2DbPath + "-wal"),
            v1: FileStamp.read(v1DbPath),
            v1Wal: FileStamp.read(v1DbPath + "-wal"),
            appRunning: appRunning
        )
        let acpEntries = computeACPSummaryStampEntries(now: now)
        let acpFp = ACPSummaryFingerprint(entries: acpEntries)

        cacheLock.lock()
        let revalidateDue = (nextRevalidateAt != nil && now >= nextRevalidateAt!)
        let hasDirtyACP = !dirtyACPSummaryPaths.isEmpty
        let t3Age = abs(now.timeIntervalSince(lastT3ScanAt))
        let maxAge: TimeInterval = lastScanHadActive ? 12.0 : 45.0
        let t3CacheFresh = (!forceFresh && lastT3Fingerprint == t3Fp && lastScanLookback == lookbackHours && t3Age < maxAge)
        if !forceFresh,
           !revalidateDue,
           !hasDirtyACP,
           t3CacheFresh,
           lastACPFingerprint == acpFp,
           let cached = cachedScanResult {
            cacheLock.unlock()
            return cached
        }
        // Fast overlay-only path: when ONLY antigravity-acp/conversation_summaries.db changed (or a timer/retry fired)
        // while statev2.sqlite is unchanged, fresh, and not under MonitorStore pre-popup fresh-commit verification,
        // reuse the cached V2 snapshot instead of re-scanning 600+ MB SQLite.
        let reusableV2Snapshot: V2TransactionSnapshot? = t3CacheFresh ? cachedV2Snapshot : nil
        let reusableV1Sessions: [AgentSession] = t3CacheFresh ? cachedV1Sessions : []
        cacheLock.unlock()

        if let v2Snap = reusableV2Snapshot {
            let v2Res = applyAntigravityOverlays(
                snapshot: v2Snap,
                acpEntries: acpEntries,
                appRunning: appRunning,
                forceFreshACP: forceFresh || hasDirtyACP,
                now: now
            )
            var results = v2Res.sessions
            if !reusableV1Sessions.isEmpty {
                let seen = Set(results.map(\.rawId))
                for s in reusableV1Sessions where !seen.contains(s.rawId) {
                    results.append(s)
                }
            }
            let finalResult = T3CodeScanResult(
                sessions: results,
                ownedNativeSessionIds: v2Res.ownedNativeSessionIds,
                pendingMatches: v2Res.pendingMatches,
                nextRevalidateAt: v2Res.nextRevalidateAt,
                deferAllCompletions: false,
                deferredSessionIds: v2Res.deferredSessionIds
            )
            let hasActive = results.contains { $0.status == .running || $0.status == .needsInput }
            cacheLock.lock()
            // CRITICAL: Never mark `lastACPFingerprint` clean while any ACP DB read failed!
            if v2Res.deferredSessionIds.isEmpty && dirtyACPSummaryPaths.isEmpty {
                lastACPFingerprint = acpFp
            }
            lastScanHadActive = hasActive
            nextRevalidateAt = v2Res.nextRevalidateAt
            cachedScanResult = finalResult
            cacheLock.unlock()
            return finalResult
        }

        var results: [AgentSession] = []
        var seenThreadIds = Set<String>()
        var ownedNativeIds = Set<String>()
        var pendingMatches: [T3PendingMatch] = []
        var nextRevalidate: Date? = nil
        var freshV2Snapshot: V2TransactionSnapshot? = nil
        var freshV1Sessions: [AgentSession] = []
        var deferredIds = Set<String>()
        var hadT3DBFailure = false
        let fm = FileManager.default

        if fm.fileExists(atPath: v2DbPath) {
            if let v2 = SQLiteReader(path: v2DbPath),
               let v2Snap = v2.withReadTransaction({
                   scanV2Locked(reader: v2, lookbackHours: lookbackHours, now: now, appRunning: appRunning, forceFresh: forceFresh)
               }) {
                freshV2Snapshot = v2Snap
                let v2Res = applyAntigravityOverlays(
                    snapshot: v2Snap,
                    acpEntries: acpEntries,
                    appRunning: appRunning,
                    forceFreshACP: forceFresh || hasDirtyACP,
                    now: now
                )
                for s in v2Res.sessions {
                    seenThreadIds.insert(s.rawId)
                    results.append(s)
                }
                ownedNativeIds.formUnion(v2Res.ownedNativeSessionIds)
                pendingMatches.append(contentsOf: v2Res.pendingMatches)
                nextRevalidate = v2Res.nextRevalidateAt
                deferredIds.formUnion(v2Res.deferredSessionIds)
            } else {
                hadT3DBFailure = true
            }
        }

        if fm.fileExists(atPath: v1DbPath) {
            if let v1 = SQLiteReader(path: v1DbPath),
               let v1Sessions = scanV1(reader: v1, excluding: seenThreadIds, lookbackHours: lookbackHours, now: now) {
                freshV1Sessions = v1Sessions
                results.append(contentsOf: v1Sessions)
            } else {
                hadT3DBFailure = true
            }
        }

        if hadT3DBFailure {
            let retryAt = now.addingTimeInterval(1.5)
            cacheLock.lock()
            let fallback = cachedScanResult
            nextRevalidateAt = retryAt
            cacheLock.unlock()
            if let fallback, results.isEmpty {
                // Never confirm completion from a stale fallback snapshot while T3 DB is locked;
                // set `deferAllCompletions = true` so MonitorStore pauses `.t3code` completion popups until fresh read.
                return T3CodeScanResult(
                    sessions: fallback.sessions,
                    ownedNativeSessionIds: fallback.ownedNativeSessionIds,
                    pendingMatches: fallback.pendingMatches,
                    nextRevalidateAt: appRunning ? retryAt : nil,
                    deferAllCompletions: true,
                    deferredSessionIds: []
                )
            }
            return T3CodeScanResult(
                sessions: results,
                ownedNativeSessionIds: ownedNativeIds,
                pendingMatches: pendingMatches,
                nextRevalidateAt: retryAt,
                deferAllCompletions: true,
                deferredSessionIds: deferredIds
            )
        }

        let finalResult = T3CodeScanResult(
            sessions: results,
            ownedNativeSessionIds: ownedNativeIds,
            pendingMatches: pendingMatches,
            nextRevalidateAt: nextRevalidate,
            deferAllCompletions: false,
            deferredSessionIds: deferredIds
        )
        let hasActive = results.contains { $0.status == .running || $0.status == .needsInput }
        cacheLock.lock()
        lastT3Fingerprint = t3Fp
        if deferredIds.isEmpty && dirtyACPSummaryPaths.isEmpty {
            lastACPFingerprint = acpFp
        }
        lastT3ScanAt = now
        lastScanLookback = lookbackHours
        lastScanHadActive = hasActive
        nextRevalidateAt = nextRevalidate
        cachedV2Snapshot = freshV2Snapshot
        cachedV1Sessions = freshV1Sessions
        cachedScanResult = finalResult
        cacheLock.unlock()
        return finalResult
    }

    // MARK: - Orchestration v2 (statev2.sqlite)

    private struct V2Project {
        let title: String
        let workspaceRoot: String
    }

    private struct V2Thread {
        let threadId: String
        let projectId: String
        let title: String
        let defaultProvider: String
        let createdAt: Date
        let updatedAt: Date
        let worktreePath: String
        let parentThreadId: String?
        let rootThreadId: String?
        let activeProviderThreadId: String?
        let providerInstanceId: String?
    }

    private struct V2Run {
        let runId: String
        let threadId: String
        let ordinal: Int
        let provider: String
        let status: String
        let requestedAt: Date?
        let completedAt: Date?
        let providerThreadId: String?
        let providerInstanceId: String?
    }

    private enum V2HandoffKind: Sendable {
        case sendMessage
        case invokeSubagent
        case backgroundCommand
    }

    private struct V2HandoffTool: Sendable {
        let kind: V2HandoffKind
        let recipientId: String
        let nativeItemId: String
        let startedAt: Date?
        let completedAt: Date
        let isExplicitBackground: Bool
    }

    private struct V2RunDetail {
        var hasPendingApproval: Bool = false
        var pendingPrompt: String = ""
        var activeSubagents: Int = 0
        var latestAction: String = ""
        var latestActivityAt: Date?
        var handoffTools: [V2HandoffTool] = []
    }

    private struct V2PendingTaskRow {
        let threadId: String
        let providerThreadId: String
        let providerInstanceId: String
        let taskId: String
        let kind: String
        let childThreadId: String
        let updatedAt: Date?
    }

    private struct V2SubagentRow {
        let threadId: String
        let runId: String
        let providerThreadId: String
        let providerInstanceId: String
        let childThreadId: String
        let status: String
        let deliveryState: String
        let latestAt: Date?
    }

    private struct V2RuntimeRequestRow {
        let threadId: String
        let nodeId: String
        let providerTurnId: String
        let kind: String
        let prompt: String
        let createdAt: Date?
    }

    private struct V2HandoffCandidate {
        let sessionIndex: Int
        let threadId: String
        let runId: String
        let parentNativeId: String
        let completedAt: Date
        let tools: [V2HandoffTool]
    }

    private struct V2AntigravitySessionRef {
        let sessionIndex: Int
        let threadId: String
        let runId: String
        let parentNativeId: String
        let runStatus: String
        let runRequestedAt: Date?
        let runCompletedAt: Date?
    }

    private struct V2TransactionSnapshot {
        var sessions: [AgentSession]
        let ownedNativeSessionIds: Set<String>
        let pendingMatches: [T3PendingMatch]
        let antigravitySessionRefs: [V2AntigravitySessionRef]
        let handoffCandidates: [V2HandoffCandidate]
    }

    /// Applies live Antigravity ACP summary DB state + post-ACP-idle seam + verified handoff fallback
    /// STRICTLY OUTSIDE statev2.sqlite's read transaction so WAL checkpointing is never delayed.
    private func applyAntigravityOverlays(
        snapshot: V2TransactionSnapshot,
        acpEntries: [ACPFileStampEntry],
        appRunning: Bool,
        forceFreshACP: Bool,
        now: Date
    ) -> T3CodeScanResult {
        var sessions = snapshot.sessions
        var promotedByACP = Set<Int>()
        var earliestRevalidate: Date? = nil
        func noteRevalidate(_ date: Date) {
            if earliestRevalidate == nil || date < earliestRevalidate! {
                earliestRevalidate = date
            }
        }

        // Layer 1 (Primary): Read Antigravity ACP's live `conversation_summaries.db` (~180 KB, ~0.16 ms, fingerprint-cached).
        // Captures exact live state that T3 Code's projection misses:
        //  - Subagents actively running (`parent_conversation_id == parentNativeId`, full ancestor chain) for ANY duration
        //  - Parent woken up & thinking (`RUNNING`/`BUSY`/`CANCELING`) before T3 creates Run N+1 (e.g. 52s TTFT gap)
        //  - Native approval/user-input waits (`WAITING_FOR_USER`) before T3 projects them
        //  - Background `run_command` / timer tasks (`not_fully_idle == 1`; daemons are natively excluded by ACP)
        let acpLive: ACPLiveSnapshot
        if !snapshot.antigravitySessionRefs.isEmpty && !acpEntries.isEmpty {
            acpLive = loadAntigravityACPLiveSnapshot(
                entries: acpEntries,
                appRunning: appRunning,
                forceFresh: forceFreshACP,
                now: now
            )
        } else {
            acpLive = ACPLiveSnapshot(rowsById: [:], activeByRootId: [:], latestModifiedByRootId: [:], expiredActiveRootIds: [], hadReadFailure: false)
        }

        if acpLive.hadReadFailure {
            noteRevalidate(now.addingTimeInterval(1.5))
        }

        let liveRefThreads = Set(snapshot.antigravitySessionRefs.map(\.threadId))
        cacheLock.lock()
        var prevActiveMap = lastACPActiveByThread
        var prevFinishedMap = lastACPFinishedByThread
        cacheLock.unlock()

        // Prune vanished threads to keep per-thread transition memory strictly bounded
        prevActiveMap = prevActiveMap.filter { liveRefThreads.contains($0.key) }
        prevFinishedMap = prevFinishedMap.filter { liveRefThreads.contains($0.key) }

        for ref in snapshot.antigravitySessionRefs {
            // Clear stale transition records as soon as a newer Run N+1 appears in T3 SQLite
            if let existing = prevActiveMap[ref.threadId], existing.runId != ref.runId {
                prevActiveMap.removeValue(forKey: ref.threadId)
            }
            if let existingFin = prevFinishedMap[ref.threadId], existingFin.runId != ref.runId {
                prevFinishedMap.removeValue(forKey: ref.threadId)
            }

            let old = sessions[ref.sessionIndex]
            let acpState = ref.parentNativeId.isEmpty ? nil : acpLive.activeByRootId[ref.parentNativeId]

            if let acpState {
                if let expiry = acpState.earliestStaleExpiry {
                    noteRevalidate(expiry)
                }
                let latestAct = max(old.updatedAt, acpState.latestActivity)
                // Only record post-ACP-idle seam eligibility when ACP actually proved out-of-band work
                // (a completed T3 run still active in ACP, OR active child subagents / background tasks),
                // so a normal turn where T3 and ACP finish together notifies right after 4.5s debounce.
                let hasOutOfBandACPWork = (old.status == .done && ref.runStatus == "completed")
                    || acpState.activeChildCount > 0
                    || (acpState.parentNotFullyIdle && !acpState.parentRunning)
                if hasOutOfBandACPWork {
                    prevActiveMap[ref.threadId] = (
                        runId: ref.runId,
                        seenAt: now,
                        latestActivity: max(now, acpState.latestActivity),
                        idleObservedAt: nil
                    )
                    prevFinishedMap.removeValue(forKey: ref.threadId)
                }

                if acpState.needsUserInput && (old.status == .running || (old.status == .done && ref.runStatus == "completed")) {
                    sessions[ref.sessionIndex] = AgentSession(
                        id: old.id,
                        rawId: old.rawId,
                        kind: old.kind,
                        title: old.title,
                        project: old.project,
                        cwd: old.cwd,
                        isCLI: old.isCLI,
                        status: .needsInput,
                        currentAction: "等待你的审批或回复",
                        detailSummary: old.detailSummary,
                        startedAt: old.startedAt,
                        updatedAt: latestAct,
                        completedAt: nil,
                        durationSec: nil,
                        activeSubagents: max(old.activeSubagents, acpState.activeChildCount),
                        isUnread: false
                    )
                    promotedByACP.insert(ref.sessionIndex)
                } else if old.status == .done && ref.runStatus == "completed" {
                    let action: String
                    if acpState.activeChildCount > 0 {
                        action = "等待 \(acpState.activeChildCount) 个子 Agent 执行…"
                    } else if acpState.parentRunning {
                        action = "思考与执行中…"
                    } else {
                        action = "后台任务运行中…"
                    }
                    sessions[ref.sessionIndex] = AgentSession(
                        id: old.id,
                        rawId: old.rawId,
                        kind: old.kind,
                        title: old.title,
                        project: old.project,
                        cwd: old.cwd,
                        isCLI: old.isCLI,
                        status: .running,
                        currentAction: action,
                        detailSummary: old.detailSummary,
                        startedAt: old.startedAt,
                        updatedAt: latestAct,
                        completedAt: nil,
                        durationSec: nil,
                        activeSubagents: max(old.activeSubagents, acpState.activeChildCount),
                        isUnread: false
                    )
                    promotedByACP.insert(ref.sessionIndex)
                } else if old.status == .running && acpState.activeChildCount > old.activeSubagents {
                    sessions[ref.sessionIndex] = AgentSession(
                        id: old.id,
                        rawId: old.rawId,
                        kind: old.kind,
                        title: old.title,
                        project: old.project,
                        cwd: old.cwd,
                        isCLI: old.isCLI,
                        status: old.status,
                        currentAction: old.currentAction,
                        detailSummary: old.detailSummary,
                        startedAt: old.startedAt,
                        updatedAt: latestAct,
                        completedAt: nil,
                        durationSec: nil,
                        activeSubagents: acpState.activeChildCount,
                        isUnread: false
                    )
                }
            } else if old.status == .done && ref.runStatus == "completed" {
                let hasCredibleIdleEvidence: Bool = {
                    guard !acpLive.hadReadFailure,
                          !ref.parentNativeId.isEmpty,
                          !acpLive.expiredActiveRootIds.contains(ref.parentNativeId),
                          let parentRow = acpLive.rowsById[ref.parentNativeId],
                          !parentRow.killed,
                          parentRow.status == "CASCADE_RUN_STATUS_IDLE",
                          !parentRow.notFullyIdle,
                          parentRow.lastModified != nil else {
                        return false
                    }
                    return true
                }()

                // Post-ACP-idle seam: anchor at `idleObservedAt` (the FIRST tick we observe credible ACP IDLE),
                // never at stale `prevActive.seenAt`, so preceding cache-hit ticks can never exhaust the 12s window!
                if var prevActive = prevActiveMap[ref.threadId], prevActive.runId == ref.runId {
                    if appRunning && acpLive.hadReadFailure {
                        sessions[ref.sessionIndex] = AgentSession(
                            id: old.id,
                            rawId: old.rawId,
                            kind: old.kind,
                            title: old.title,
                            project: old.project,
                            cwd: old.cwd,
                            isCLI: old.isCLI,
                            status: .running,
                            currentAction: "同步运行状态…",
                            detailSummary: old.detailSummary,
                            startedAt: old.startedAt,
                            updatedAt: max(old.updatedAt, prevActive.latestActivity),
                            completedAt: nil,
                            durationSec: nil,
                            activeSubagents: old.activeSubagents,
                            isUnread: false
                        )
                        promotedByACP.insert(ref.sessionIndex)
                        noteRevalidate(now.addingTimeInterval(1.5))
                    } else if hasCredibleIdleEvidence {
                        let observedAt = prevActive.idleObservedAt ?? now
                        if prevActive.idleObservedAt == nil {
                            prevActive.idleObservedAt = observedAt
                            prevActiveMap[ref.threadId] = prevActive
                        }
                        let diskFinishedAt = acpLive.latestModifiedByRootId[ref.parentNativeId].map { min($0, now) }
                        let effectiveFinishedAt: Date = {
                            if let disk = diskFinishedAt, disk >= prevActive.seenAt {
                                return max(old.completedAt ?? disk, disk)
                            }
                            // ACP flipped IDLE without advancing last_modified_time -> use `observedAt` so post-launch
                            // completions never fall back before `launchTime` and get auto-acked.
                            return max(old.completedAt ?? observedAt, observedAt)
                        }()
                        let seamDeadline = observedAt.addingTimeInterval(acpIdleSeamSeconds)
                        if appRunning && now < seamDeadline {
                            sessions[ref.sessionIndex] = AgentSession(
                                id: old.id,
                                rawId: old.rawId,
                                kind: old.kind,
                                title: old.title,
                                project: old.project,
                                cwd: old.cwd,
                                isCLI: old.isCLI,
                                status: .running,
                                currentAction: "等待主会话接续…",
                                detailSummary: old.detailSummary,
                                startedAt: old.startedAt,
                                updatedAt: max(old.updatedAt, effectiveFinishedAt),
                                completedAt: nil,
                                durationSec: nil,
                                activeSubagents: old.activeSubagents,
                                isUnread: false
                            )
                            promotedByACP.insert(ref.sessionIndex)
                            noteRevalidate(seamDeadline)
                        } else {
                            // Seam elapsed with clean, credible ACP IDLE and no Run N+1:
                            // record actual completion timestamp so duration never jumps backward
                            // and post-launch ACP finishes of pre-launch runs still notify cleanly.
                            prevFinishedMap[ref.threadId] = (runId: ref.runId, finishedAt: effectiveFinishedAt)
                            prevActiveMap.removeValue(forKey: ref.threadId)
                        }
                    } else {
                        // ACP state is unknown / expired (>1800s) / missing / unparseable:
                        // drop active hold WITHOUT fabricating a new `finishedAt`, preventing phantom alerts for old/crashed runs.
                        prevActiveMap.removeValue(forKey: ref.threadId)
                    }
                }

                if !promotedByACP.contains(ref.sessionIndex),
                   let fin = prevFinishedMap[ref.threadId],
                   fin.runId == ref.runId {
                    let updatedDur: TimeInterval? = {
                        if let start = ref.runRequestedAt ?? old.startedAt {
                            let d = fin.finishedAt.timeIntervalSince(start)
                            return d >= 0 ? d : old.durationSec
                        }
                        return old.durationSec
                    }()
                    sessions[ref.sessionIndex] = AgentSession(
                        id: old.id,
                        rawId: old.rawId,
                        kind: old.kind,
                        title: old.title,
                        project: old.project,
                        cwd: old.cwd,
                        isCLI: old.isCLI,
                        status: old.status,
                        currentAction: old.currentAction,
                        detailSummary: old.detailSummary,
                        startedAt: old.startedAt,
                        updatedAt: max(old.updatedAt, fin.finishedAt),
                        completedAt: fin.finishedAt,
                        durationSec: updatedDur,
                        activeSubagents: old.activeSubagents,
                        isUnread: false
                    )
                }
            }
        }

        cacheLock.lock()
        lastACPActiveByThread = prevActiveMap
        lastACPFinishedByThread = prevFinishedMap
        cacheLock.unlock()

        // Layer 2 (Verified Handoff Fallback):
        //  Evaluate EVERY qualifying tail candidate in reverse ordinal order until one verifies!
        //  - For `send_message`: preserve full 150s fallback unless ACP cleanly confirms IDLE for BOTH parent AND recipient (>= tool.completedAt).
        //  - For `invoke_subagent`: preserve full 150s fallback unless ACP already observed out-of-band work finish for this run.
        //  - For finite `backgroundCommand` (Run 40/42 shape, verified via `.system_generated/tasks/task-*.log` or explicit marker):
        //    hold up to 25s even when ACP was never sampled active between ticks (and never masked by a later 11s sync command!).
        if appRunning && handoffGraceSeconds > 0 && !snapshot.handoffCandidates.isEmpty {
            for cand in snapshot.handoffCandidates {
                guard !promotedByACP.contains(cand.sessionIndex) else { continue }
                let old = sessions[cand.sessionIndex]
                guard old.status == .done else { continue }

                for tool in cand.tools {
                    let effectiveGrace: TimeInterval
                    let actionText: String
                    switch tool.kind {
                    case .backgroundCommand:
                        effectiveGrace = min(handoffGraceSeconds, 25.0)
                        actionText = "等待后台命令返回…"
                    case .sendMessage, .invokeSubagent:
                        let hasConfirmedRecipientTerminalIdle: Bool = {
                            guard !acpLive.hadReadFailure,
                                  !cand.parentNativeId.isEmpty,
                                  !acpLive.expiredActiveRootIds.contains(cand.parentNativeId),
                                  let parentRow = acpLive.rowsById[cand.parentNativeId],
                                  !parentRow.killed,
                                  parentRow.status == "CASCADE_RUN_STATUS_IDLE",
                                  !parentRow.notFullyIdle,
                                  let parentLM = parentRow.lastModified,
                                  parentLM >= cand.completedAt.addingTimeInterval(-2.0) else {
                                return false
                            }
                            if tool.kind == .sendMessage {
                                guard !tool.recipientId.isEmpty,
                                      let recRow = acpLive.rowsById[tool.recipientId],
                                      !recRow.killed,
                                      recRow.status == "CASCADE_RUN_STATUS_IDLE",
                                      !recRow.notFullyIdle,
                                      let recLM = recRow.lastModified else {
                                    return false
                                }
                                return recLM >= tool.completedAt
                            }
                            return prevFinishedMap[cand.threadId]?.runId == cand.runId
                        }()
                        effectiveGrace = hasConfirmedRecipientTerminalIdle ? min(handoffGraceSeconds, 20.0) : handoffGraceSeconds
                        actionText = "等待子代理返回…"
                    }
                    let deadline = cand.completedAt.addingTimeInterval(effectiveGrace)
                    guard now < deadline else { continue }
                    if !verifyAntigravityHandoff(candidate: cand, tool: tool, now: now) {
                        if tool.kind != .backgroundCommand {
                            // Subagent descriptor file may not be flushed yet; retry on next tick while inside window.
                            noteRevalidate(now.addingTimeInterval(1.5))
                        }
                        continue
                    }

                    sessions[cand.sessionIndex] = AgentSession(
                        id: old.id,
                        rawId: old.rawId,
                        kind: old.kind,
                        title: old.title,
                        project: old.project,
                        cwd: old.cwd,
                        isCLI: old.isCLI,
                        status: .running,
                        currentAction: actionText,
                        detailSummary: old.detailSummary,
                        startedAt: old.startedAt,
                        updatedAt: old.updatedAt,
                        completedAt: nil,
                        durationSec: nil,
                        activeSubagents: tool.kind == .backgroundCommand ? old.activeSubagents : max(1, old.activeSubagents),
                        isUnread: false
                    )
                    noteRevalidate(deadline)
                    break
                }
            }
        }

        // Scope ACP read failure deferral strictly to emitted Antigravity T3 sessions (never blocking Codex/Claude T3 sessions!)
        var deferredIds = Set<String>()
        if acpLive.hadReadFailure {
            for ref in snapshot.antigravitySessionRefs {
                deferredIds.insert(sessions[ref.sessionIndex].id)
            }
        }

        return T3CodeScanResult(
            sessions: sessions,
            ownedNativeSessionIds: snapshot.ownedNativeSessionIds,
            pendingMatches: snapshot.pendingMatches,
            nextRevalidateAt: earliestRevalidate,
            deferAllCompletions: false,
            deferredSessionIds: deferredIds
        )
    }

    private func scanV2Locked(reader: SQLiteReader, lookbackHours: Double, now: Date, appRunning: Bool, forceFresh: Bool = false) -> V2TransactionSnapshot? {
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)

        // 1. Projects map
        var projects: [String: V2Project] = [:]
        _ = reader.query("SELECT project_id, title, workspace_root FROM projection_projects;") { stmt in
            let pid = SQLiteReader.string(stmt, 0)
            let title = SQLiteReader.string(stmt, 1)
            let root = SQLiteReader.string(stmt, 2)
            if !pid.isEmpty {
                projects[pid] = V2Project(title: title, workspaceRoot: root)
            }
        }

        // 2. Latest run per thread
        var latestRuns: [String: V2Run] = [:]
        let runsOk = reader.query("""
            SELECT run_id, thread_id, ordinal, provider, status, requested_at, completed_at, payload_json
            FROM orchestration_v2_projection_runs
            ORDER BY thread_id ASC, ordinal DESC, requested_at DESC;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 1)
            guard !tid.isEmpty, latestRuns[tid] == nil else { return }
            let runPayload = Self.parseJSONObject(SQLiteReader.string(stmt, 7))
            let ptid = (runPayload["providerThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let piid = (runPayload["providerInstanceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            latestRuns[tid] = V2Run(
                runId: SQLiteReader.string(stmt, 0),
                threadId: tid,
                ordinal: SQLiteReader.int(stmt, 2),
                provider: SQLiteReader.string(stmt, 3),
                status: SQLiteReader.string(stmt, 4).lowercased(),
                requestedAt: Self.parseISO(SQLiteReader.string(stmt, 5)),
                completedAt: Self.parseISO(SQLiteReader.string(stmt, 6)),
                providerThreadId: (ptid?.isEmpty == false) ? ptid : nil,
                providerInstanceId: (piid?.isEmpty == false) ? piid : nil
            )
        }
        guard runsOk else { return nil }

        // 3. Active provider runtimes (catches imported threads actively resumed inside T3 Code)
        //    Note: generic 'waiting' is treated as running unless backed by an actionable pending runtime request.
        var runningRuntimeThreads = Set<String>()
        var explicitWaitingRuntimeThreads = Set<String>()
        let runtimeOk = reader.query("""
            SELECT thread_id, status
            FROM provider_session_runtime
            WHERE lower(status) IN ('running', 'starting', 'busy', 'waiting', 'waiting_for_approval', 'waiting_for_input');
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            let st = SQLiteReader.string(stmt, 1).lowercased()
            if !tid.isEmpty {
                if Self.isExplicitApprovalStatus(st) {
                    explicitWaitingRuntimeThreads.insert(tid)
                } else {
                    runningRuntimeThreads.insert(tid)
                }
            }
        }
        if !runtimeOk && reader.tableExists("provider_session_runtime") {
            return nil
        }

        // 3b. P0-A: Structured pendingBackgroundTasks on provider_threads (hits T3 partial index verbatim!)
        var pendingTaskRows: [V2PendingTaskRow] = []
        let ptTasksOk = reader.query("""
            SELECT thread_id, provider_thread_id, provider, payload_json
            FROM orchestration_v2_projection_provider_threads
            WHERE CASE WHEN json_valid(payload_json) THEN json_array_length(payload_json, '$.pendingBackgroundTasks') > 0 ELSE 0 END;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            let ptid = SQLiteReader.string(stmt, 1)
            guard !tid.isEmpty else { return }
            let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 3))
            let piid = (payload["providerInstanceId"] as? String) ?? ""
            let ptUpdated = Self.parseISO((payload["updatedAt"] as? String) ?? "")
            guard let tasks = payload["pendingBackgroundTasks"] as? [[String: Any]] else { return }
            for task in tasks {
                let kind = (task["kind"] as? String ?? "").lowercased()
                let awaited = (task["awaited"] as? Bool) == true
                let blocksCompletion: Bool
                switch kind {
                case "subagent", "background_task":
                    blocksCompletion = true
                case "command", "monitor":
                    blocksCompletion = awaited
                default:
                    blocksCompletion = false
                }
                guard blocksCompletion else { continue }
                let taskId = (task["taskId"] as? String) ?? (task["id"] as? String) ?? ""
                let childTid = (task["childThreadId"] as? String) ?? ""
                let taskAt = Self.parseISO((task["updatedAt"] as? String) ?? (task["startedAt"] as? String) ?? "") ?? ptUpdated
                pendingTaskRows.append(V2PendingTaskRow(
                    threadId: tid,
                    providerThreadId: ptid,
                    providerInstanceId: piid,
                    taskId: taskId,
                    kind: kind,
                    childThreadId: childTid,
                    updatedAt: taskAt
                ))
            }
        }
        if !ptTasksOk && reader.tableExists("orchestration_v2_projection_provider_threads") {
            return nil
        }

        // 3c. P0-B: Structured subagents projection (active or undelivered completion)
        var activeSubagentRows: [V2SubagentRow] = []
        let subagentsOk = reader.query("""
            SELECT thread_id, run_id, provider_thread_id, provider_instance_id, child_thread_id,
                   status, completion_delivery_state, started_at, updated_at
            FROM orchestration_v2_projection_subagents
            WHERE status IN ('pending', 'running', 'waiting')
               OR (status != 'idle' AND completion_delivery_state IN ('pending', 'claimed'));
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty else { return }
            let startedAt = Self.parseISO(SQLiteReader.string(stmt, 7))
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 8)) ?? startedAt
            activeSubagentRows.append(V2SubagentRow(
                threadId: tid,
                runId: SQLiteReader.string(stmt, 1),
                providerThreadId: SQLiteReader.string(stmt, 2),
                providerInstanceId: SQLiteReader.string(stmt, 3),
                childThreadId: SQLiteReader.string(stmt, 4),
                status: SQLiteReader.string(stmt, 5).lowercased(),
                deliveryState: SQLiteReader.string(stmt, 6).lowercased(),
                latestAt: updatedAt
            ))
        }
        if !subagentsOk && reader.tableExists("orchestration_v2_projection_subagents") {
            return nil
        }

        // 3d. P0-C: Actionable pending runtime requests (hits recovery partial index `WHERE status = 'pending'`)
        var pendingRequestRows: [V2RuntimeRequestRow] = []
        let reqsOk = reader.query("""
            SELECT thread_id, node_id, provider_turn_id, kind, created_at, payload_json
            FROM orchestration_v2_projection_runtime_requests
            WHERE status = 'pending' AND resolved_at IS NULL;
            """) { stmt in
            let tid = SQLiteReader.string(stmt, 0)
            let kind = SQLiteReader.string(stmt, 3).lowercased()
            guard !tid.isEmpty else { return }
            guard kind != "dynamic_tool_call" && kind != "auth_refresh" else { return }
            let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 5))
            if let cap = payload["responseCapability"] as? [String: Any],
               (cap["type"] as? String)?.lowercased() == "not_resumable" {
                return
            }
            let prompt = Self.extractApprovalAction(kind: kind == "user_input" ? "user_input_request" : "approval_request", payload: payload)
            pendingRequestRows.append(V2RuntimeRequestRow(
                threadId: tid,
                nodeId: SQLiteReader.string(stmt, 1),
                providerTurnId: SQLiteReader.string(stmt, 2),
                kind: kind,
                prompt: prompt,
                createdAt: Self.parseISO(SQLiteReader.string(stmt, 4))
            ))
        }
        if !reqsOk && reader.tableExists("orchestration_v2_projection_runtime_requests") {
            return nil
        }

        // 4. Threads (non-deleted, non-archived): fetch top 100 recent PLUS any active/waiting/blocking threads
        //    and any missing root/parent threads of active children so LIMIT can never truncate active work.
        var threadsById: [String: V2Thread] = [:]
        var threadOrder: [String] = []

        func appendThreadRow(_ stmt: OpaquePointer) {
            let tid = SQLiteReader.string(stmt, 0)
            guard !tid.isEmpty, threadsById[tid] == nil else { return }
            let payloadStr = SQLiteReader.string(stmt, 6)
            let payload = Self.parseJSONObject(payloadStr)
            let worktree = payload["worktreePath"] as? String ?? ""
            let lineage = payload["lineage"] as? [String: Any]
            let parentTid = lineage?["parentThreadId"] as? String
            let rootTid = lineage?["rootThreadId"] as? String
            let activePt = (payload["activeProviderThreadId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let provInst = (payload["providerInstanceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let createdAt = Self.parseISO(SQLiteReader.string(stmt, 4)) ?? .distantPast
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 5)) ?? createdAt
            let thread = V2Thread(
                threadId: tid,
                projectId: SQLiteReader.string(stmt, 1),
                title: SQLiteReader.string(stmt, 2),
                defaultProvider: SQLiteReader.string(stmt, 3),
                createdAt: createdAt,
                updatedAt: updatedAt,
                worktreePath: worktree,
                parentThreadId: (parentTid?.isEmpty == false) ? parentTid : nil,
                rootThreadId: (rootTid?.isEmpty == false) ? rootTid : nil,
                activeProviderThreadId: (activePt?.isEmpty == false) ? activePt : nil,
                providerInstanceId: (provInst?.isEmpty == false) ? provInst : nil
            )
            threadsById[tid] = thread
            threadOrder.append(tid)
        }

        let threadsOk = reader.query("""
            SELECT thread_id, project_id, title, default_provider, created_at, updated_at, payload_json
            FROM orchestration_v2_projection_threads
            WHERE deleted_at IS NULL AND archived_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 100;
            """, rowHandler: appendThreadRow)
        guard threadsOk else { return nil }

        // Ensure every active/waiting/blocking thread (from latestRuns, runtime, P0-A/B/C) is included beyond LIMIT 100
        var missingThreadIds = Set<String>()
        for (tid, run) in latestRuns where Self.isActiveRunStatus(run.status) || Self.isExplicitApprovalStatus(run.status) || Self.isGenericWaitingStatus(run.status) {
            if threadsById[tid] == nil { missingThreadIds.insert(tid) }
        }
        for tid in runningRuntimeThreads where threadsById[tid] == nil { missingThreadIds.insert(tid) }
        for tid in explicitWaitingRuntimeThreads where threadsById[tid] == nil { missingThreadIds.insert(tid) }
        for row in pendingTaskRows {
            if threadsById[row.threadId] == nil { missingThreadIds.insert(row.threadId) }
            if !row.childThreadId.isEmpty && threadsById[row.childThreadId] == nil { missingThreadIds.insert(row.childThreadId) }
        }
        for row in activeSubagentRows {
            if threadsById[row.threadId] == nil { missingThreadIds.insert(row.threadId) }
            if !row.childThreadId.isEmpty && threadsById[row.childThreadId] == nil { missingThreadIds.insert(row.childThreadId) }
        }
        for row in pendingRequestRows where threadsById[row.threadId] == nil {
            missingThreadIds.insert(row.threadId)
        }

        func fetchMissingThreads(_ ids: Set<String>) {
            guard !ids.isEmpty else { return }
            let inClause = ids.map { Self.sqlLiteral($0) }.joined(separator: ",")
            _ = reader.query("""
                SELECT thread_id, project_id, title, default_provider, created_at, updated_at, payload_json
                FROM orchestration_v2_projection_threads
                WHERE deleted_at IS NULL AND archived_at IS NULL
                  AND thread_id IN (\(inClause));
                """, rowHandler: appendThreadRow)
        }
        fetchMissingThreads(missingThreadIds)

        // Ensure parents/roots of any loaded child threads are also loaded before rollup
        var missingParents = Set<String>()
        for th in threadsById.values {
            if let rootId = th.rootThreadId, threadsById[rootId] == nil { missingParents.insert(rootId) }
            if let parentId = th.parentThreadId, threadsById[parentId] == nil { missingParents.insert(parentId) }
        }
        fetchMissingThreads(missingParents)

        let threads = threadOrder.compactMap { threadsById[$0] }

        // Group actionable pending runtime requests by threadId (and roll up child -> root below)
        var actionableRequestByThread: [String: V2RuntimeRequestRow] = [:]
        for req in pendingRequestRows {
            guard threadsById[req.threadId] != nil else { continue }
            if actionableRequestByThread[req.threadId] == nil {
                actionableRequestByThread[req.threadId] = req
            }
        }

        // Separate root threads vs child subagent threads so child runs roll up cleanly onto their root thread
        var childRunningByRoot: [String: Int] = [:]
        var activeChildThreadIdsByRoot: [String: Set<String>] = [:]
        var childNeedsInputByRoot: [String: String] = [:]
        var childThreadIdsByRoot: [String: [String]] = [:]
        var rootThreads: [V2Thread] = []

        for th in threads {
            if let parentId = th.parentThreadId {
                let rootKey = th.rootThreadId ?? parentId
                childThreadIdsByRoot[rootKey, default: []].append(th.threadId)
                let childRun = latestRuns[th.threadId]
                let childExplicitWaiting = explicitWaitingRuntimeThreads.contains(th.threadId)
                let childRunningRuntime = runningRuntimeThreads.contains(th.threadId)
                if let req = actionableRequestByThread[th.threadId] {
                    childNeedsInputByRoot[rootKey] = req.prompt
                } else if let run = childRun {
                    if Self.isExplicitApprovalStatus(run.status) || childExplicitWaiting {
                        guard let detail = inspectV2Run(reader: reader, threadId: th.threadId, runId: run.runId, includeHandoffScan: false) else {
                            return nil
                        }
                        childNeedsInputByRoot[rootKey] = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
                    } else if Self.isActiveRunStatus(run.status) || Self.isGenericWaitingStatus(run.status) || childRunningRuntime {
                        guard let detail = inspectV2Run(reader: reader, threadId: th.threadId, runId: run.runId, includeHandoffScan: false) else {
                            return nil
                        }
                        if detail.hasPendingApproval {
                            childNeedsInputByRoot[rootKey] = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
                        } else {
                            childRunningByRoot[rootKey, default: 0] += 1
                            activeChildThreadIdsByRoot[rootKey, default: []].insert(th.threadId)
                        }
                    }
                } else if childExplicitWaiting {
                    childNeedsInputByRoot[rootKey] = "等待你的审批或回复"
                } else if childRunningRuntime {
                    childRunningByRoot[rootKey, default: 0] += 1
                    activeChildThreadIdsByRoot[rootKey, default: []].insert(th.threadId)
                }
                continue
            }
            rootThreads.append(th)
        }

        // Roll up P0-A pendingBackgroundTasks & P0-B subagents onto root threads with owner verification + dedupe
        var blockingCountByRoot: [String: Int] = [:]
        var blockingActivityByRoot: [String: Date] = [:]
        var seenBlockingKeysByRoot: [String: Set<String>] = [:]

        func resolveRootKey(for threadId: String) -> String? {
            guard let th = threadsById[threadId] else { return nil }
            if let parentId = th.parentThreadId {
                return th.rootThreadId ?? parentId
            }
            return th.threadId
        }

        for task in pendingTaskRows {
            guard let ownerThread = threadsById[task.threadId],
                  let rootKey = resolveRootKey(for: task.threadId) else { continue }
            if let activePt = ownerThread.activeProviderThreadId, !task.providerThreadId.isEmpty, activePt != task.providerThreadId {
                continue
            }
            if let ownerInst = ownerThread.providerInstanceId, !task.providerInstanceId.isEmpty, ownerInst != task.providerInstanceId {
                continue
            }
            // If linked child thread already reached a terminal run state, do not count stale task
            if !task.childThreadId.isEmpty,
               let childRun = latestRuns[task.childThreadId],
               !Self.isActiveRunStatus(childRun.status) && !Self.isExplicitApprovalStatus(childRun.status) && !Self.isGenericWaitingStatus(childRun.status) {
                continue
            }
            if !task.childThreadId.isEmpty && (activeChildThreadIdsByRoot[rootKey]?.contains(task.childThreadId) == true) {
                continue
            }
            let dedupeKey = !task.childThreadId.isEmpty ? "child:\(task.childThreadId)" : "task:\(task.taskId.isEmpty ? task.kind : task.taskId)"
            if seenBlockingKeysByRoot[rootKey, default: []].insert(dedupeKey).inserted {
                blockingCountByRoot[rootKey, default: 0] += 1
                if let at = task.updatedAt, blockingActivityByRoot[rootKey] == nil || at > blockingActivityByRoot[rootKey]! {
                    blockingActivityByRoot[rootKey] = at
                }
            }
        }

        for sub in activeSubagentRows {
            guard let ownerThread = threadsById[sub.threadId],
                  let rootKey = resolveRootKey(for: sub.threadId) else { continue }
            if let ownerInst = ownerThread.providerInstanceId, !sub.providerInstanceId.isEmpty, ownerInst != sub.providerInstanceId {
                continue
            }
            // Ownership check: match activeProviderThreadId when present; if blank, require verifiable runId or active childThreadId
            if !sub.providerThreadId.isEmpty {
                if let activePt = ownerThread.activeProviderThreadId, activePt != sub.providerThreadId {
                    continue
                }
            } else {
                let matchesLatestRun = !sub.runId.isEmpty && (latestRuns[sub.threadId]?.runId == sub.runId)
                let childIsLive = !sub.childThreadId.isEmpty && {
                    if let cr = latestRuns[sub.childThreadId] {
                        return Self.isActiveRunStatus(cr.status) || Self.isExplicitApprovalStatus(cr.status) || Self.isGenericWaitingStatus(cr.status)
                    }
                    return runningRuntimeThreads.contains(sub.childThreadId) || explicitWaitingRuntimeThreads.contains(sub.childThreadId)
                }()
                let awaitingDelivery = (sub.deliveryState == "pending" || sub.deliveryState == "claimed") && !sub.childThreadId.isEmpty && threadsById[sub.childThreadId] != nil
                guard matchesLatestRun || childIsLive || awaitingDelivery else { continue }
            }
            // Exclude stale completed child threads that are NOT awaiting completion delivery
            let awaitingDelivery = (sub.deliveryState == "pending" || sub.deliveryState == "claimed")
            if !awaitingDelivery,
               !sub.childThreadId.isEmpty,
               let childRun = latestRuns[sub.childThreadId],
               !Self.isActiveRunStatus(childRun.status) && !Self.isExplicitApprovalStatus(childRun.status) && !Self.isGenericWaitingStatus(childRun.status) {
                continue
            }
            if !sub.childThreadId.isEmpty && (activeChildThreadIdsByRoot[rootKey]?.contains(sub.childThreadId) == true) {
                continue
            }
            let dedupeKey = !sub.childThreadId.isEmpty ? "child:\(sub.childThreadId)" : "sub:\(sub.runId):\(sub.threadId)"
            if seenBlockingKeysByRoot[rootKey, default: []].insert(dedupeKey).inserted {
                blockingCountByRoot[rootKey, default: 0] += 1
                if let at = sub.latestAt, blockingActivityByRoot[rootKey] == nil || at > blockingActivityByRoot[rootKey]! {
                    blockingActivityByRoot[rootKey] = at
                }
            }
        }

        // 5. Inspect nodes & turn items only for recent or active runs (caching terminal completed runs including handoff metadata)
        var runDetails: [String: V2RunDetail] = [:]
        for th in rootThreads {
            guard let run = latestRuns[th.threadId] else { continue }
            let isPotentiallyActive = Self.isActiveRunStatus(run.status)
                || Self.isExplicitApprovalStatus(run.status)
                || Self.isGenericWaitingStatus(run.status)
                || runningRuntimeThreads.contains(th.threadId)
                || explicitWaitingRuntimeThreads.contains(th.threadId)
                || actionableRequestByThread[th.threadId] != nil
                || (blockingCountByRoot[th.threadId] ?? 0) > 0
            let isAntigravityGraceCandidate: Bool = {
                guard appRunning && handoffGraceSeconds > 0,
                      run.status == "completed",
                      Self.normalizeProviderKey(run.provider) == AgentKind.antigravity.rawValue,
                      let comp = run.completedAt,
                      comp >= launchTime else { return false }
                let elapsed = now.timeIntervalSince(comp)
                return elapsed >= -5.0 && elapsed < handoffGraceSeconds
            }()
            guard isPotentiallyActive || isAntigravityGraceCandidate || th.updatedAt >= cutoff else { continue }
            let recentForFreshCheck: Bool = {
                guard forceFresh else { return false }
                let refTime = run.completedAt ?? th.updatedAt
                return abs(now.timeIntervalSince(refTime)) < 300
            }()
            if !isPotentiallyActive && !recentForFreshCheck {
                cacheLock.lock()
                let cached = terminalRunDetailCache[run.runId]
                cacheLock.unlock()
                if let cached {
                    runDetails[run.runId] = cached
                    continue
                }
            }
            guard let detail = inspectV2Run(
                reader: reader,
                threadId: th.threadId,
                runId: run.runId,
                includeHandoffScan: isAntigravityGraceCandidate
            ) else {
                return nil
            }
            runDetails[run.runId] = detail
            if !isPotentiallyActive && !detail.hasPendingApproval {
                cacheLock.lock()
                if terminalRunDetailCache.count >= 120 {
                    terminalRunDetailCache.removeAll(keepingCapacity: true)
                }
                terminalRunDetailCache[run.runId] = detail
                cacheLock.unlock()
            }
        }

        // 6. Build AgentSession list FIRST so we know exactly which threads are actually visible
        var sessions: [AgentSession] = []
        var emittedRootThreadIds = Set<String>()
        var pendingCandidates: [(threadId: String, providerKey: String, normalizedCwd: String, startedAt: Date)] = []
        var antigravitySessionIndices: [(sessionIndex: Int, threadId: String, run: V2Run)] = []
        var handoffCandidateIndices: [(sessionIndex: Int, threadId: String, run: V2Run, completedAt: Date, tools: [V2HandoffTool])] = []

        for th in rootThreads {
            let run = latestRuns[th.threadId]
            let runtimeActive = runningRuntimeThreads.contains(th.threadId)
            let runtimeExplicitWaiting = explicitWaitingRuntimeThreads.contains(th.threadId)
            let rootActionableReq = actionableRequestByThread[th.threadId]

            // Skip untouched imported threads (e.g. `import:codex:<uuid>`) that have never run in T3 Code,
            // preventing duplicates of threads already shown by CodexScanner / ClaudeScanner.
            if th.threadId.hasPrefix("import:") && run == nil && !runtimeActive && !runtimeExplicitWaiting && rootActionableReq == nil {
                continue
            }

            let detail = run.flatMap { runDetails[$0.runId] } ?? V2RunDetail()
            let childRunning = childRunningByRoot[th.threadId] ?? 0
            let structuredBlocking = blockingCountByRoot[th.threadId] ?? 0
            let totalBackgroundRunning = childRunning + structuredBlocking
            let childNeedsPrompt = childNeedsInputByRoot[th.threadId]

            let activityCandidates: [Date] = [th.updatedAt, run?.requestedAt, run?.completedAt, detail.latestActivityAt, blockingActivityByRoot[th.threadId], rootActionableReq?.createdAt]
                .compactMap { $0 }
                .filter { $0 > .distantPast }
            let latestActivity = activityCandidates.max() ?? th.updatedAt

            // Determine raw status
            var status: SessionStatus
            var action: String

            if let childPrompt = childNeedsPrompt {
                status = .needsInput
                action = childPrompt
            } else if let req = rootActionableReq {
                status = .needsInput
                action = req.prompt
            } else if detail.hasPendingApproval {
                status = .needsInput
                action = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
            } else if runtimeExplicitWaiting {
                status = .needsInput
                action = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
            } else if let run {
                if Self.isExplicitApprovalStatus(run.status) {
                    status = .needsInput
                    action = detail.pendingPrompt.isEmpty ? "等待你的审批或回复" : detail.pendingPrompt
                } else if Self.isActiveRunStatus(run.status) || Self.isGenericWaitingStatus(run.status) {
                    status = .running
                    action = detail.latestAction.isEmpty ? "思考与执行中…" : detail.latestAction
                } else if run.status == "failed" || run.status == "error" {
                    status = .error
                    action = "执行出错"
                } else if run.status == "cancelled" || run.status == "canceled" || run.status == "interrupted" {
                    status = .canceled
                    action = "已手动停止"
                } else {
                    status = .done
                    action = "已完成"
                }
            } else if runtimeActive {
                status = .running
                action = "执行中…"
            } else {
                status = .done
                action = "已完成"
            }

            // Roll up active child threads & P0-A/P0-B structured background work onto an idle parent thread
            if status == .done && totalBackgroundRunning > 0 {
                status = .running
                action = "等待 \(totalBackgroundRunning) 个子 Agent 执行…"
            }

            // Stale guard if T3 Code crashed / was quit mid-run leaving an unclosed row in SQLite
            let idleAge = now.timeIntervalSince(latestActivity)
            if status == .running && !appRunning && idleAge > 180 {
                status = .done
                action = "已完成"
            } else if status == .running && idleAge > 900 {
                status = .done
                action = "已完成"
            } else if status == .needsInput && !appRunning && idleAge > 600 {
                status = .done
                action = "已完成"
            }

            let isActive = (status == .running || status == .needsInput)
            guard isActive || latestActivity >= cutoff else { continue }

            let proj = projects[th.projectId]
            let cwd = !th.worktreePath.isEmpty ? th.worktreePath : (proj?.workspaceRoot ?? "")
            let projectName = Self.resolveProjectName(project: proj, worktreePath: th.worktreePath)
            let cleanTitle = ProjectNameHelper.cleanOneLine(th.title, maxLength: 78)
            let displayTitle = cleanTitle.isEmpty ? (projectName.isEmpty ? "T3 Code 对话" : projectName) : cleanTitle

            let startedAt = run?.requestedAt ?? (th.createdAt > .distantPast ? th.createdAt : nil)
            let completedAt: Date? = isActive ? nil : (run?.completedAt ?? (latestActivity > .distantPast ? latestActivity : nil))
            let durationSec: TimeInterval? = {
                guard !isActive, let s = run?.requestedAt, let c = completedAt else { return nil }
                let d = c.timeIntervalSince(s)
                return d >= 0 ? d : nil
            }()

            let activeSubs = max(detail.activeSubagents, totalBackgroundRunning)

            emittedRootThreadIds.insert(th.threadId)

            if isActive,
               let provKey = Self.normalizeProviderKey(run?.provider ?? th.defaultProvider),
               !cwd.isEmpty,
               let start = startedAt {
                pendingCandidates.append((
                    threadId: th.threadId,
                    providerKey: provKey,
                    normalizedCwd: Self.normalizePath(cwd),
                    startedAt: start
                ))
            }

            let sessionIdx = sessions.count
            sessions.append(AgentSession(
                id: "t3code:\(th.threadId)",
                rawId: th.threadId,
                kind: .t3code,
                title: displayTitle,
                project: projectName,
                cwd: cwd,
                isCLI: false,
                status: status,
                currentAction: action,
                detailSummary: "",
                startedAt: startedAt,
                updatedAt: latestActivity,
                completedAt: completedAt,
                durationSec: durationSec,
                activeSubagents: activeSubs,
                isUnread: false
            ))

            // Record emitted Antigravity sessions so Layer 1 can cross-check live ACP `conversation_summaries.db`
            if let run,
               Self.normalizeProviderKey(run.provider) == AgentKind.antigravity.rawValue {
                antigravitySessionIndices.append((
                    sessionIndex: sessionIdx,
                    threadId: th.threadId,
                    run: run
                ))
            }

            // P1 candidate: freshly completed post-launch Antigravity run whose tail has subagent or background command candidates
            if status == .done,
               appRunning,
               handoffGraceSeconds > 0,
               let run,
               run.status == "completed",
               let comp = run.completedAt,
               comp >= launchTime,
               now.timeIntervalSince(comp) < handoffGraceSeconds,
               !detail.handoffTools.isEmpty {
                let qualifyingTools = detail.handoffTools.filter { tool in
                    let toolToEndGap = comp.timeIntervalSince(tool.completedAt)
                    return toolToEndGap >= -5.0 && toolToEndGap <= 45.0
                }
                if !qualifyingTools.isEmpty {
                    handoffCandidateIndices.append((
                        sessionIndex: sessionIdx,
                        threadId: th.threadId,
                        run: run,
                        completedAt: comp,
                        tools: qualifyingTools
                    ))
                }
            }
        }

        // 7. Map ONLY emitted T3 threads (and their rolled-up child threads) to underlying native session IDs.
        //    Archived, deleted, out-of-window, or untouched imported threads never suppress standalone sessions.
        var ownedThreadIds = emittedRootThreadIds
        for rootId in emittedRootThreadIds {
            if let children = childThreadIdsByRoot[rootId] {
                ownedThreadIds.formUnion(children)
            }
        }

        var ownedNativeIds = Set<String>()
        var threadsWithNativeRef = Set<String>()
        struct AgyProviderThreadBinding {
            let providerThreadId: String
            let providerInstanceId: String
            let nativeId: String
        }
        var agyBindingsByThread: [String: [AgyProviderThreadBinding]] = [:]
        var agyRuntimeNativeIdByThread: [String: String] = [:]
        if !ownedThreadIds.isEmpty {
            let inClause = ownedThreadIds.map { Self.sqlLiteral($0) }.joined(separator: ",")
            let ptMapOk = reader.query("""
                SELECT thread_id, provider_thread_id, provider, payload_json
                FROM orchestration_v2_projection_provider_threads
                WHERE thread_id IN (\(inClause));
                """) { stmt in
                let tid = SQLiteReader.string(stmt, 0)
                guard !tid.isEmpty, ownedThreadIds.contains(tid) else { return }
                let ptid = SQLiteReader.string(stmt, 1)
                let colProvider = SQLiteReader.string(stmt, 2)
                let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 3))
                let piid = (payload["providerInstanceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let ref = payload["nativeThreadRef"] as? [String: Any],
                   let nativeId = ref["nativeId"] as? String,
                   !nativeId.isEmpty,
                   !nativeId.hasPrefix("pending:") {
                    let rawDriver = (ref["driver"] as? String) ?? colProvider
                    if let key = Self.normalizeProviderKey(rawDriver) {
                        ownedNativeIds.insert("\(key):\(nativeId)")
                        threadsWithNativeRef.insert(tid)
                        if key == AgentKind.antigravity.rawValue {
                            agyBindingsByThread[tid, default: []].append(AgyProviderThreadBinding(
                                providerThreadId: ptid,
                                providerInstanceId: piid,
                                nativeId: nativeId
                            ))
                        }
                    }
                }
            }
            if !ptMapOk && reader.tableExists("orchestration_v2_projection_provider_threads") {
                return nil
            }

            if reader.hasColumn("resume_cursor_json", in: "provider_session_runtime")
                && reader.hasColumn("provider_name", in: "provider_session_runtime") {
                let rtMapOk = reader.query("""
                    SELECT thread_id, provider_name, resume_cursor_json
                    FROM provider_session_runtime
                    WHERE thread_id IN (\(inClause));
                    """) { stmt in
                    let tid = SQLiteReader.string(stmt, 0)
                    guard !tid.isEmpty, ownedThreadIds.contains(tid) else { return }
                    let rawProvider = SQLiteReader.string(stmt, 1)
                    let cursor = Self.parseJSONObject(SQLiteReader.string(stmt, 2))
                    if let nativeId = (cursor["threadId"] as? String) ?? (cursor["sessionId"] as? String),
                       !nativeId.isEmpty,
                       !nativeId.hasPrefix("pending:"),
                       let key = Self.normalizeProviderKey(rawProvider) {
                        ownedNativeIds.insert("\(key):\(nativeId)")
                        threadsWithNativeRef.insert(tid)
                        if key == AgentKind.antigravity.rawValue && agyRuntimeNativeIdByThread[tid] == nil {
                            agyRuntimeNativeIdByThread[tid] = nativeId
                        }
                    }
                }
                if !rtMapOk {
                    return nil
                }
            }
        }

        // Strict run-bound Antigravity nativeId resolution (no instance-mismatch or arbitrary multi-row fallback):
        // 1. If `run.providerThreadId` is set -> require matching `providerThreadId` + compatible `providerInstanceId`.
        // 2. Else if `thread.activeProviderThreadId` is set -> require matching `providerThreadId` + compatible `providerInstanceId`.
        // 3. Else bind only when unambiguous (single binding or runtime cursor when no bindings exist).
        func resolvedAntigravityNativeId(for threadId: String, run: V2Run) -> String {
            let bindings = agyBindingsByThread[threadId] ?? []
            if let runPt = run.providerThreadId, !runPt.isEmpty {
                return bindings.first(where: { b in
                    b.providerThreadId == runPt
                        && (run.providerInstanceId == nil || b.providerInstanceId.isEmpty || b.providerInstanceId == run.providerInstanceId)
                })?.nativeId ?? ""
            }
            if let th = threadsById[threadId], let activePt = th.activeProviderThreadId, !activePt.isEmpty {
                return bindings.first(where: { b in
                    b.providerThreadId == activePt
                        && (th.providerInstanceId == nil || b.providerInstanceId.isEmpty || b.providerInstanceId == th.providerInstanceId)
                })?.nativeId ?? ""
            }
            if bindings.count == 1, let only = bindings.first {
                return only.nativeId
            }
            if bindings.isEmpty {
                return agyRuntimeNativeIdByThread[threadId] ?? ""
            }
            return ""
        }

        let pendingMatches: [T3PendingMatch] = pendingCandidates.compactMap { cand in
            guard !threadsWithNativeRef.contains(cand.threadId) else { return nil }
            return T3PendingMatch(
                providerKey: cand.providerKey,
                normalizedCwd: cand.normalizedCwd,
                startedAt: cand.startedAt
            )
        }

        let antigravitySessionRefs: [V2AntigravitySessionRef] = antigravitySessionIndices.map { item in
            V2AntigravitySessionRef(
                sessionIndex: item.sessionIndex,
                threadId: item.threadId,
                runId: item.run.runId,
                parentNativeId: resolvedAntigravityNativeId(for: item.threadId, run: item.run),
                runStatus: item.run.status,
                runRequestedAt: item.run.requestedAt,
                runCompletedAt: item.run.completedAt
            )
        }

        let handoffCandidates: [V2HandoffCandidate] = handoffCandidateIndices.map { c in
            V2HandoffCandidate(
                sessionIndex: c.sessionIndex,
                threadId: c.threadId,
                runId: c.run.runId,
                parentNativeId: resolvedAntigravityNativeId(for: c.threadId, run: c.run),
                completedAt: c.completedAt,
                tools: c.tools
            )
        }

        return V2TransactionSnapshot(
            sessions: sessions,
            ownedNativeSessionIds: ownedNativeIds,
            pendingMatches: pendingMatches,
            antigravitySessionRefs: antigravitySessionRefs,
            handoffCandidates: handoffCandidates
        )
    }

    private func cachedAntigravitySummaryDBPaths(now: Date) -> [String] {
        cacheLock.lock()
        if let cached = antigravitySummaryDBPathsCache {
            let ttl: TimeInterval = cached.paths.isEmpty ? 30 : 300
            if abs(now.timeIntervalSince(cached.loadedAt)) < ttl {
                cacheLock.unlock()
                return cached.paths
            }
        }
        cacheLock.unlock()

        let fm = FileManager.default
        var paths: [String] = []
        if let entries = try? fm.contentsOfDirectory(atPath: antigravityProvidersRoot) {
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let dbPath = "\(antigravityProvidersRoot)/\(entry)/antigravity-acp/conversation_summaries.db"
                if fm.fileExists(atPath: dbPath) {
                    paths.append(dbPath)
                }
            }
        }

        let livePathSet = Set(paths)
        cacheLock.lock()
        antigravitySummaryDBPathsCache = (paths, now)
        cachedACPSummaryRowsByPath = cachedACPSummaryRowsByPath.filter { livePathSet.contains($0.key) }
        cacheLock.unlock()
        return paths
    }

    private func computeACPSummaryStampEntries(now: Date) -> [ACPFileStampEntry] {
        cachedAntigravitySummaryDBPaths(now: now).map { path in
            ACPFileStampEntry(
                path: path,
                db: FileStamp.read(path),
                wal: FileStamp.read(path + "-wal")
            )
        }
    }

    private static func isACPActiveStatus(_ status: String) -> Bool {
        status == "CASCADE_RUN_STATUS_RUNNING"
            || status == "CASCADE_RUN_STATUS_BUSY"
            || status == "CASCADE_RUN_STATUS_CANCELING"
    }

    private static func isACPWaitingForUserStatus(_ status: String) -> Bool {
        status == "CASCADE_RUN_STATUS_WAITING_FOR_USER"
            || status == "STATE_WAITING_FOR_USER"
    }

    private func loadAntigravityACPLiveSnapshot(
        entries: [ACPFileStampEntry],
        appRunning: Bool,
        forceFresh: Bool,
        now: Date
    ) -> ACPLiveSnapshot {
        var allRows: [ACPConversationSummaryRow] = []
        var mergedParentTable: [String: String] = [:]
        var hadReadFailure = false
        let livePathSet = Set(entries.map(\.path))
        let fm = FileManager.default

        cacheLock.lock()
        cachedACPSummaryRowsByPath = cachedACPSummaryRowsByPath.filter { livePathSet.contains($0.key) }
        dirtyACPSummaryPaths = dirtyACPSummaryPaths.filter { livePathSet.contains($0) }
        cacheLock.unlock()

        for entry in entries {
            cacheLock.lock()
            let cached = cachedACPSummaryRowsByPath[entry.path]
            let isDirty = dirtyACPSummaryPaths.contains(entry.path)
            cacheLock.unlock()

            let rows: [ACPConversationSummaryRow]
            let parentTable: [String: String]
            if !forceFresh, !isDirty, let cached, cached.stamp == entry {
                rows = cached.rows
                parentTable = cached.parentTable
            } else if !fm.fileExists(atPath: entry.path) {
                // Deleted DB path: evict immediately instead of treating as a 300s read failure!
                cacheLock.lock()
                cachedACPSummaryRowsByPath.removeValue(forKey: entry.path)
                dirtyACPSummaryPaths.remove(entry.path)
                antigravitySummaryDBPathsCache = nil
                cacheLock.unlock()
                continue
            } else if let reader = SQLiteReader(path: entry.path),
                      let loaded = readACPSummaryDB(reader: reader) {
                rows = loaded.rows
                parentTable = loaded.parentTable
                cacheLock.lock()
                cachedACPSummaryRowsByPath[entry.path] = (entry, rows, parentTable)
                dirtyACPSummaryPaths.remove(entry.path)
                cacheLock.unlock()
            } else {
                hadReadFailure = true
                cacheLock.lock()
                dirtyACPSummaryPaths.insert(entry.path)
                cacheLock.unlock()
                if let cached {
                    // Keep last good rows for display ONLY; path stays marked dirty so even an
                    // unchanged FileStamp retries on the next tick and pauses completion confirmation.
                    rows = cached.rows
                    parentTable = cached.parentTable
                } else {
                    continue
                }
            }
            allRows.append(contentsOf: rows)
            for (k, v) in parentTable { mergedParentTable[k] = v }
        }

        var byId: [String: ACPConversationSummaryRow] = [:]
        for row in allRows {
            if let existing = byId[row.id] {
                if (row.lastModified ?? .distantPast) >= (existing.lastModified ?? .distantPast) {
                    byId[row.id] = row
                }
            } else {
                byId[row.id] = row
            }
        }

        // Returns nil if a cycle is detected or depth exceeds 8 hops without reaching a root.
        func rootConversationId(for id: String) -> String? {
            var cur = id
            var visited: Set<String> = [id]
            for _ in 0..<8 {
                let p: String
                if let row = byId[cur], !row.parentId.isEmpty {
                    p = row.parentId
                } else {
                    p = mergedParentTable[cur] ?? ""
                }
                if p.isEmpty {
                    return cur
                }
                guard visited.insert(p).inserted else {
                    return nil // cycle -> unattributable
                }
                cur = p
            }
            // Exceeded 8 hops: only return if cur itself has no further parent
            let tailParent = (byId[cur]?.parentId.isEmpty == false ? byId[cur]!.parentId : (mergedParentTable[cur] ?? ""))
            return tailParent.isEmpty ? cur : nil
        }

        var activeByRootId: [String: ACPRootActiveState] = [:]
        var latestModifiedByRootId: [String: Date] = [:]
        var expiredActiveRootIds = Set<String>()
        let staleLimit: TimeInterval = appRunning ? 1800 : 180
        for row in byId.values {
            // Backfilled `killed = 1` ancestors exist ONLY for walking parent links; never count them as active or completion timestamps!
            guard !row.killed else { continue }
            guard let rootId = rootConversationId(for: row.id), !rootId.isEmpty else { continue }
            if let lm = row.lastModified {
                if latestModifiedByRootId[rootId] == nil || lm > latestModifiedByRootId[rootId]! {
                    latestModifiedByRootId[rootId] = lm
                }
            }

            let isActiveStatus = Self.isACPActiveStatus(row.status)
            let isWaitingUser = Self.isACPWaitingForUserStatus(row.status)
            guard isActiveStatus || isWaitingUser || row.notFullyIdle else { continue }
            guard let lm = row.lastModified else {
                expiredActiveRootIds.insert(rootId)
                continue
            }
            let staleAge = now.timeIntervalSince(lm)
            if staleAge > staleLimit {
                expiredActiveRootIds.insert(rootId)
                continue
            }

            var state = activeByRootId[rootId] ?? ACPRootActiveState()
            if isWaitingUser {
                state.needsUserInput = true
            }
            if rootId == row.id {
                if isActiveStatus {
                    state.parentRunning = true
                }
                if row.notFullyIdle {
                    state.parentNotFullyIdle = true
                }
            } else {
                state.activeChildCount += 1
            }
            if lm > state.latestActivity {
                state.latestActivity = lm
            }
            let expiry = lm.addingTimeInterval(staleLimit)
            if state.earliestStaleExpiry == nil || expiry < state.earliestStaleExpiry! {
                state.earliestStaleExpiry = expiry
            }
            activeByRootId[rootId] = state
        }

        return ACPLiveSnapshot(
            rowsById: byId,
            activeByRootId: activeByRootId,
            latestModifiedByRootId: latestModifiedByRootId,
            expiredActiveRootIds: expiredActiveRootIds,
            hadReadFailure: hadReadFailure
        )
    }

    private func readACPSummaryDB(reader: SQLiteReader) -> (rows: [ACPConversationSummaryRow], parentTable: [String: String])? {
        reader.withReadTransaction {
            var parentTable: [String: String] = [:]
            if reader.tableExists("conversation_parents") {
                let parentsOk = reader.query("SELECT conversation_id, parent_id FROM conversation_parents;") { stmt in
                    let cid = SQLiteReader.string(stmt, 0)
                    let pid = SQLiteReader.string(stmt, 1)
                    if !cid.isEmpty && !pid.isEmpty { parentTable[cid] = pid }
                }
                guard parentsOk else { return nil }
            }

            var rowsById: [String: ACPConversationSummaryRow] = [:]
            func appendRow(_ stmt: OpaquePointer) {
                let id = SQLiteReader.string(stmt, 0)
                guard !id.isEmpty, rowsById[id] == nil else { return }
                let rawDate = SQLiteReader.string(stmt, 4)
                rowsById[id] = ACPConversationSummaryRow(
                    id: id,
                    parentId: SQLiteReader.string(stmt, 1),
                    status: SQLiteReader.string(stmt, 2),
                    notFullyIdle: SQLiteReader.int(stmt, 3) != 0,
                    killed: SQLiteReader.int(stmt, 5) != 0,
                    lastModified: FastISO8601Parser.parse(rawDate, allowBareUTC: true)
                )
            }

            // 1. Always fetch all active / waiting / not_fully_idle non-killed rows (never truncated by LIMIT)
            let activeSql = """
            SELECT conversation_id, parent_conversation_id, status, not_fully_idle, last_modified_time, killed
            FROM conversation_summaries
            WHERE killed = 0
              AND (status IN ('CASCADE_RUN_STATUS_RUNNING', 'CASCADE_RUN_STATUS_BUSY', 'CASCADE_RUN_STATUS_CANCELING', 'CASCADE_RUN_STATUS_WAITING_FOR_USER', 'STATE_WAITING_FOR_USER')
                   OR not_fully_idle != 0);
            """
            guard reader.query(activeSql, rowHandler: appendRow) else { return nil }

            // 2. Fetch the 500 most recent non-killed rows (covers parent/recipient freshness checks & shallow chains)
            let recentSql = """
            SELECT conversation_id, parent_conversation_id, status, not_fully_idle, last_modified_time, killed
            FROM conversation_summaries
            WHERE killed = 0
            ORDER BY last_modified_time DESC
            LIMIT 500;
            """
            guard reader.query(recentSql, rowHandler: appendRow) else { return nil }

            // 3. Backfill any missing ancestors referenced by loaded rows via PK seeks (keeping `killed` flag
            //    so killed intermediate ancestors provide parent links ONLY and can never reactivate as active!).
            for _ in 0..<6 {
                var missingParents = Set<String>()
                for row in rowsById.values {
                    if !row.parentId.isEmpty && rowsById[row.parentId] == nil {
                        missingParents.insert(row.parentId)
                    }
                }
                guard !missingParents.isEmpty else { break }
                let inClause = missingParents.map { Self.sqlLiteral($0) }.joined(separator: ",")
                let ancSql = """
                SELECT conversation_id, parent_conversation_id, status, not_fully_idle, last_modified_time, killed
                FROM conversation_summaries
                WHERE conversation_id IN (\(inClause));
                """
                let beforeCount = rowsById.count
                guard reader.query(ancSql, rowHandler: appendRow) else { return nil }
                if rowsById.count == beforeCount { break }
            }

            return (Array(rowsById.values), parentTable)
        }
    }

    private func verifyAntigravityHandoff(candidate: V2HandoffCandidate, tool: V2HandoffTool, now: Date) -> Bool {
        let cacheKey = "\(candidate.parentNativeId)|\(candidate.runId)|\(tool.kind)|\(tool.nativeItemId)|\(tool.recipientId)"
        cacheLock.lock()
        if handoffVerificationCache[cacheKey] == true {
            cacheLock.unlock()
            return true
        }
        cacheLock.unlock()

        let verified: Bool
        switch tool.kind {
        case .invokeSubagent:
            // `invoke_subagent` completed cleanly inside the final 45s of the run
            verified = true
        case .sendMessage:
            let parentId = candidate.parentNativeId
            let recipient = tool.recipientId
            if parentId.isEmpty || recipient.isEmpty {
                verified = false
            } else {
                let brainDirs = cachedAntigravityBrainDirs(now: now)
                let fm = FileManager.default
                verified = brainDirs.contains { brainDir in
                    let subFile = "\(brainDir)/\(parentId)/.system_generated/subagents/\(recipient).json"
                    return fm.fileExists(atPath: subFile)
                }
            }
        case .backgroundCommand:
            if tool.isExplicitBackground {
                verified = true
            } else {
                let parentId = candidate.parentNativeId
                if parentId.isEmpty {
                    verified = false
                } else {
                    let brainDirs = cachedAntigravityBrainDirs(now: now)
                    let fm = FileManager.default
                    let windowStart = (tool.startedAt ?? tool.completedAt).addingTimeInterval(-2.0)
                    let windowEnd = tool.completedAt.addingTimeInterval(30.0)
                    verified = brainDirs.contains { brainDir in
                        let sysGen = "\(brainDir)/\(parentId)/.system_generated"
                        // 1. Undelivered background message still waiting for parent pickup
                        let undeliveredDir = "\(sysGen)/messages/undelivered"
                        if let items = try? fm.contentsOfDirectory(atPath: undeliveredDir),
                           items.contains(where: { !$0.hasPrefix(".") }) {
                            return true
                        }
                        // 2. Background task log (`tasks/task-*.log`) written during this command's execution window
                        //    (distinguishes genuine backgrounded commands like Run 40/42 from synchronous commands!)
                        let tasksDir = "\(sysGen)/tasks"
                        guard let files = try? fm.contentsOfDirectory(atPath: tasksDir) else { return false }
                        for name in files where name.hasPrefix("task-") {
                            let fullPath = "\(tasksDir)/\(name)"
                            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                               let mtime = attrs[.modificationDate] as? Date,
                               mtime >= windowStart && mtime <= windowEnd {
                                return true
                            }
                        }
                        return false
                    }
                }
            }
        }

        // Only cache positive verifications so a temporarily unflushed descriptor/task file retries cleanly.
        if verified {
            cacheLock.lock()
            if handoffVerificationCache.count >= 128 {
                handoffVerificationCache.removeAll(keepingCapacity: true)
            }
            handoffVerificationCache[cacheKey] = true
            cacheLock.unlock()
        }
        return verified
    }

    private func cachedAntigravityBrainDirs(now: Date) -> [String] {
        cacheLock.lock()
        if let cached = antigravityBrainDirsCache, abs(now.timeIntervalSince(cached.loadedAt)) < 300 {
            cacheLock.unlock()
            return cached.dirs
        }
        cacheLock.unlock()

        let fm = FileManager.default
        var dirs: [String] = []
        if let entries = try? fm.contentsOfDirectory(atPath: antigravityProvidersRoot) {
            for entry in entries where !entry.hasPrefix(".") {
                let brain = "\(antigravityProvidersRoot)/\(entry)/antigravity-acp/brain"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: brain, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(brain)
                }
            }
        }

        cacheLock.lock()
        antigravityBrainDirsCache = (dirs, now)
        cacheLock.unlock()
        return dirs
    }

    private func inspectV2Run(reader: SQLiteReader, threadId: String, runId: String, includeHandoffScan: Bool) -> V2RunDetail? {
        var detail = V2RunDetail()
        let escapedThreadId = Self.sqlLiteral(threadId)
        let escapedRunId = Self.sqlLiteral(runId)

        // Check active/waiting nodes scoped by (thread_id, run_id) to hit `orchestration_v2_projection_nodes_thread_run_idx`
        let nodesOk = reader.query("""
            SELECT kind, status, started_at, completed_at, payload_json
            FROM orchestration_v2_projection_nodes
            WHERE thread_id = \(escapedThreadId) AND run_id = \(escapedRunId)
            ORDER BY rowid DESC
            LIMIT 40;
            """) { stmt in
            let kind = SQLiteReader.string(stmt, 0).lowercased()
            let st = SQLiteReader.string(stmt, 1).lowercased()
            let startedAt = Self.parseISO(SQLiteReader.string(stmt, 2))
            let completedStr = SQLiteReader.string(stmt, 3)
            let isUnfinished = completedStr.isEmpty

            if let s = startedAt, detail.latestActivityAt == nil || s > detail.latestActivityAt! {
                detail.latestActivityAt = s
            }

            if isUnfinished && (kind == "approval_request" || kind == "user_input_request" || Self.isExplicitApprovalStatus(st)) {
                detail.hasPendingApproval = true
                if detail.pendingPrompt.isEmpty {
                    let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 4))
                    detail.pendingPrompt = Self.extractApprovalAction(kind: kind, payload: payload)
                }
            } else if isUnfinished && kind == "subagent" && (Self.isActiveRunStatus(st) || Self.isExplicitApprovalStatus(st) || Self.isGenericWaitingStatus(st) || st == "pending") {
                detail.activeSubagents += 1
            }
        }
        if !nodesOk && reader.tableExists("orchestration_v2_projection_nodes") {
            return nil
        }

        // Dedicated indexed check for pending approval/user_input turn items so LIMIT 12 can never truncate them
        let hasTurnItemsTable = reader.tableExists("orchestration_v2_projection_turn_items")
        let apprItemsOk = reader.query("""
            SELECT type, status, updated_at, payload_json
            FROM orchestration_v2_projection_turn_items
            WHERE thread_id = \(escapedThreadId)
              AND run_id = \(escapedRunId)
              AND type IN ('approval_request', 'user_input_request')
              AND status IN ('pending', 'running', 'waiting')
            ORDER BY ordinal DESC
            LIMIT 4;
            """) { stmt in
            let itemType = SQLiteReader.string(stmt, 0).lowercased()
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 2))
            if let u = updatedAt, detail.latestActivityAt == nil || u > detail.latestActivityAt! {
                detail.latestActivityAt = u
            }
            detail.hasPendingApproval = true
            if detail.pendingPrompt.isEmpty {
                let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 3))
                detail.pendingPrompt = Self.extractApprovalAction(kind: itemType, payload: payload)
            }
        }
        if !apprItemsOk && hasTurnItemsTable {
            return nil
        }

        // Check recent turn items for latest live tool action (scoped by thread_id + run_id!)
        let recentItemsOk = reader.query("""
            SELECT type, status, updated_at, payload_json
            FROM orchestration_v2_projection_turn_items
            WHERE thread_id = \(escapedThreadId) AND run_id = \(escapedRunId)
            ORDER BY ordinal DESC, rowid DESC
            LIMIT 12;
            """) { stmt in
            let itemType = SQLiteReader.string(stmt, 0).lowercased()
            let st = SQLiteReader.string(stmt, 1).lowercased()
            let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 2))
            let payloadStr = SQLiteReader.string(stmt, 3)

            if let u = updatedAt, detail.latestActivityAt == nil || u > detail.latestActivityAt! {
                detail.latestActivityAt = u
            }

            let isTerminalItem = ["completed", "resolved", "approved", "denied", "rejected", "cancelled", "canceled", "failed", "interrupted"].contains(st)
            if (itemType == "approval_request" || itemType == "user_input_request") && !isTerminalItem {
                detail.hasPendingApproval = true
                if detail.pendingPrompt.isEmpty {
                    let payload = Self.parseJSONObject(payloadStr)
                    detail.pendingPrompt = Self.extractApprovalAction(kind: itemType, payload: payload)
                }
            }

            if detail.latestAction.isEmpty && itemType != "user_message" && itemType != "checkpoint" && itemType != "system_notice" {
                let payload = Self.parseJSONObject(payloadStr)
                let described = Self.describeTurnItem(type: itemType, payload: payload)
                if !described.isEmpty {
                    detail.latestAction = described
                }
            }
        }
        if !recentItemsOk && hasTurnItemsTable {
            return nil
        }

        // Dedicated indexed check for Antigravity send_message / invoke_subagent handoff tools (never truncated by LIMIT 12!)
        if includeHandoffScan {
            var latestNotificationAt: Date? = nil
            let notifOk = reader.query("""
                SELECT updated_at
                FROM orchestration_v2_projection_turn_items
                WHERE thread_id = \(escapedThreadId) AND run_id = \(escapedRunId) AND type = 'notification'
                ORDER BY ordinal DESC
                LIMIT 1;
                """) { stmt in
                latestNotificationAt = Self.parseISO(SQLiteReader.string(stmt, 0))
            }
            if !notifOk && hasTurnItemsTable {
                return nil
            }

            let handoffOk = reader.query("""
                SELECT updated_at, payload_json
                FROM orchestration_v2_projection_turn_items
                WHERE thread_id = \(escapedThreadId) AND run_id = \(escapedRunId) AND type = 'dynamic_tool' AND status = 'completed'
                ORDER BY ordinal DESC
                LIMIT 8;
                """) { stmt in
                let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 0))
                let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 1))
                let toolName = ((payload["toolName"] as? String) ?? (payload["title"] as? String) ?? (payload["name"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let isSendMsg = toolName == "send_message" || toolName == "run send_message"
                let isInvokeSub = toolName == "invoke_subagent" || toolName == "run invoke_subagent"
                guard isSendMsg || isInvokeSub else { return }

                let toolCompletedAt = Self.parseISO((payload["completedAt"] as? String) ?? "") ?? updatedAt
                guard let toolCompletedAt else { return }
                // Skip if a background notification already arrived after this tool call inside the same run
                if let notifAt = latestNotificationAt, notifAt > toolCompletedAt {
                    return
                }
                let nativeItemId = ((payload["nativeItemRef"] as? [String: Any])?["nativeId"] as? String) ?? ""
                var recipientId = ""
                if isSendMsg {
                    if let inputObj = payload["input"] as? [String: Any] {
                        recipientId = ((inputObj["Recipient"] as? String) ?? (inputObj["recipient"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let inputStr = payload["input"] as? String {
                        let parsed = Self.parseJSONObject(inputStr)
                        recipientId = ((parsed["Recipient"] as? String) ?? (parsed["recipient"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !recipientId.isEmpty else { return }
                }
                detail.handoffTools.append(V2HandoffTool(
                    kind: isSendMsg ? .sendMessage : .invokeSubagent,
                    recipientId: recipientId,
                    nativeItemId: nativeItemId,
                    startedAt: Self.parseISO((payload["startedAt"] as? String) ?? ""),
                    completedAt: toolCompletedAt,
                    isExplicitBackground: false
                ))
            }
            if !handoffOk && hasTurnItemsTable {
                return nil
            }

            // Retain ALL qualifying tail `command_execution` candidates (up to 4) so an unverified later
            // 11s synchronous command can NEVER shadow an earlier genuine backgrounded command (`tasks/task-*.log`)!
            let cmdHandoffOk = reader.query("""
                SELECT status, updated_at, payload_json
                FROM orchestration_v2_projection_turn_items
                WHERE thread_id = \(escapedThreadId) AND run_id = \(escapedRunId) AND type = 'command_execution'
                ORDER BY ordinal DESC
                LIMIT 4;
                """) { stmt in
                let st = SQLiteReader.string(stmt, 0).lowercased()
                let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 1))
                let payload = Self.parseJSONObject(SQLiteReader.string(stmt, 2))
                let startedAt = Self.parseISO((payload["startedAt"] as? String) ?? "")
                let cmdCompletedAt = Self.parseISO((payload["completedAt"] as? String) ?? "") ?? updatedAt
                guard let cmdCompletedAt else { return }
                if let notifAt = latestNotificationAt, notifAt > cmdCompletedAt {
                    return
                }
                let output = ((payload["output"] as? String) ?? "").lowercased()
                let isRunningCmd = (st == "running" || st == "pending" || st == "waiting")
                let explicitBg = isRunningCmd
                    || output.contains("running as a background task")
                    || output.contains("with task id:")
                let exceededSyncWait = startedAt.map { cmdCompletedAt.timeIntervalSince($0) >= 9.5 } ?? false
                guard explicitBg || exceededSyncWait else { return }
                let nativeItemId = ((payload["nativeItemRef"] as? [String: Any])?["nativeId"] as? String) ?? ""
                detail.handoffTools.append(V2HandoffTool(
                    kind: .backgroundCommand,
                    recipientId: "",
                    nativeItemId: nativeItemId,
                    startedAt: startedAt,
                    completedAt: cmdCompletedAt,
                    isExplicitBackground: explicitBg
                ))
            }
            if !cmdHandoffOk && hasTurnItemsTable {
                return nil
            }
        }

        return detail
    }

    // MARK: - Legacy T3 Code v1 (state.sqlite) Fallback

    private func scanV1(reader: SQLiteReader, excluding seen: Set<String>, lookbackHours: Double, now: Date) -> [AgentSession]? {
        reader.withReadTransaction {
            let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
            var projects: [String: V2Project] = [:]
            _ = reader.query("SELECT project_id, title, workspace_root FROM projection_projects;") { stmt in
                let pid = SQLiteReader.string(stmt, 0)
                if !pid.isEmpty {
                    projects[pid] = V2Project(title: SQLiteReader.string(stmt, 1), workspaceRoot: SQLiteReader.string(stmt, 2))
                }
            }

            var results: [AgentSession] = []
            let ok = reader.query("""
                SELECT thread_id, project_id, title, worktree_path, created_at, updated_at,
                       pending_approval_count, pending_user_input_count
                FROM projection_threads
                WHERE deleted_at IS NULL AND archived_at IS NULL
                ORDER BY updated_at DESC
                LIMIT 50;
                """) { stmt in
                let tid = SQLiteReader.string(stmt, 0)
                guard !tid.isEmpty, !seen.contains(tid) else { return }
                let updatedAt = Self.parseISO(SQLiteReader.string(stmt, 5)) ?? .distantPast
                let pendingApprovals = SQLiteReader.int(stmt, 6)
                let pendingInputs = SQLiteReader.int(stmt, 7)
                let needsInput = pendingApprovals > 0 || pendingInputs > 0
                guard needsInput || updatedAt >= cutoff else { return }

                let proj = projects[SQLiteReader.string(stmt, 1)]
                let worktree = SQLiteReader.string(stmt, 3)
                let projectName = Self.resolveProjectName(project: proj, worktreePath: worktree)
                let cleanTitle = ProjectNameHelper.cleanOneLine(SQLiteReader.string(stmt, 2), maxLength: 78)

                results.append(AgentSession(
                    id: "t3code:\(tid)",
                    rawId: tid,
                    kind: .t3code,
                    title: cleanTitle.isEmpty ? "T3 Code 对话" : cleanTitle,
                    project: projectName,
                    cwd: !worktree.isEmpty ? worktree : (proj?.workspaceRoot ?? ""),
                    isCLI: false,
                    status: needsInput ? .needsInput : .done,
                    currentAction: needsInput ? "等待你的审批或回复" : "已完成",
                    detailSummary: "",
                    startedAt: Self.parseISO(SQLiteReader.string(stmt, 4)),
                    updatedAt: updatedAt,
                    completedAt: needsInput ? nil : updatedAt,
                    durationSec: nil,
                    activeSubagents: 0,
                    isUnread: false
                ))
            }
            return ok ? results : nil
        }
    }

    // MARK: - Formatting & Helpers

    private static func isActiveRunStatus(_ s: String) -> Bool {
        s == "running" || s == "starting" || s == "queued" || s == "preparing" || s == "in_progress"
    }

    private static func isExplicitApprovalStatus(_ s: String) -> Bool {
        s == "waiting_for_approval" || s == "waiting_for_input" || s == "pending_approval" || s == "needs_input"
    }

    private static func isGenericWaitingStatus(_ s: String) -> Bool {
        s == "waiting"
    }

    private static func resolveProjectName(project: V2Project?, worktreePath: String) -> String {
        if let title = project?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title.lowercased() != "no project" {
            return title
        }
        if !worktreePath.isEmpty && !worktreePath.contains("/.t3/scratch") {
            let derived = ProjectNameHelper.projectName(from: worktreePath)
            if !derived.isEmpty { return derived }
        }
        if let root = project?.workspaceRoot, !root.isEmpty && !root.contains("/.t3/scratch") {
            let derived = ProjectNameHelper.projectName(from: root)
            if !derived.isEmpty { return derived }
        }
        return "独立对话"
    }

    private static func extractApprovalAction(kind: String, payload: [String: Any]) -> String {
        let candidates = [
            payload["prompt"] as? String,
            payload["question"] as? String,
            payload["command"] as? String,
            payload["title"] as? String,
            payload["message"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if let first = candidates.first {
            let clean = ProjectNameHelper.cleanOneLine(first, maxLength: 36)
            if !clean.isEmpty {
                return "等待确认 · \(clean)"
            }
        }
        return kind == "user_input_request" ? "等待你确认/回答" : "等待你的审批或回复"
    }

    private static func describeTurnItem(type: String, payload: [String: Any]) -> String {
        let title = (payload["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "command_execution":
            let cmd = (payload["input"] as? String ?? payload["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty {
                return ToolActionFormatter.describe(name: "exec", rawInput: cmd)
            }
            return "运行终端命令"
        case "file_search":
            return "检索代码"
        case "file_change", "file_edit", "patch":
            let path = payload["path"] as? String ?? payload["filePath"] as? String ?? ""
            if !path.isEmpty {
                return "编辑 \((path as NSString).lastPathComponent)"
            }
            return "修改代码文件"
        case "dynamic_tool", "mcp_tool", "tool_call":
            let toolName = payload["toolName"] as? String ?? payload["name"] as? String ?? title
            let rawInput = payload["input"] as? String ?? ""
            if !toolName.isEmpty {
                return ToolActionFormatter.describe(name: toolName, rawInput: rawInput)
            }
            return "执行工具中…"
        case "reasoning":
            return "深度思考中…"
        case "assistant_message":
            return "输出回复中…"
        case "approval_request":
            return extractApprovalAction(kind: "approval_request", payload: payload)
        case "user_input_request":
            return extractApprovalAction(kind: "user_input_request", payload: payload)
        default:
            return title.isEmpty ? "执行中…" : ProjectNameHelper.cleanOneLine(title, maxLength: 36)
        }
    }

    private static func parseJSONObject(_ raw: String) -> [String: Any] {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    /// Strict lock-free ASCII ISO-8601 parser delegating to `FastISO8601Parser`.
    static func parseISO(_ raw: String) -> Date? {
        FastISO8601Parser.parse(raw)
    }

    private static func sqlLiteral(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func isT3CodeAppRunning() -> Bool {
        for bid in ["com.t3tools.t3code", "com.t3tools.t3code.dev"] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                return true
            }
        }
        return false
    }

    static func normalizeProviderKey(_ raw: String) -> String? {
        let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if low.isEmpty { return nil }
        if low.contains("codex") || low.contains("openai") { return AgentKind.codex.rawValue }
        if low.contains("claude") || low.contains("anthropic") { return AgentKind.claude.rawValue }
        if low.contains("antigravity") || low.contains("agy") { return AgentKind.antigravity.rawValue }
        if low.contains("cursor") { return AgentKind.cursor.rawValue }
        if low.contains("gemini") { return AgentKind.gemini.rawValue }
        if low.contains("opencode") { return AgentKind.opencode.rawValue }
        return nil
    }

    static func normalizePath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("file://"), let url = URL(string: s) {
            s = url.path
        }
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
