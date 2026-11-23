import Foundation

/// Scans hook-fed sessions for Cursor, Gemini CLI, and OpenCode (~/.lumi/live/).
final class ExtraAgentsScanner: @unchecked Sendable {
    private let supportedAgents: [(String, AgentKind)] = [
        ("cursor", .cursor),
        ("gemini", .gemini),
        ("opencode", .opencode)
    ]

    func scan(lookbackHours: Double = 24, preloadedHooksByAgent: [String: [String: LiveHookRecord]]? = nil) -> [AgentSession] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        var results: [AgentSession] = []

        for (agentKey, kind) in supportedAgents {
            let records = preloadedHooksByAgent?[agentKey] ?? LiveHookRecord.loadAll(forAgent: agentKey)
            for (sid, hook) in records {
                guard hook.updatedAt >= cutoff else { continue }
                let path = hook.workspacePaths.first ?? hook.cwd
                let project = ProjectNameHelper.projectName(from: path)
                let rawTitle = !hook.title.isEmpty ? hook.title
                    : (!hook.firstUserInput.isEmpty ? hook.firstUserInput
                       : (!hook.lastUserInput.isEmpty ? hook.lastUserInput : project))
                let title = ProjectNameHelper.cleanOneLine(
                    rawTitle.isEmpty ? "\(kind.displayName) 对话" : rawTitle,
                    maxLength: 78
                )

                let status: SessionStatus
                if hook.state == "needs_input" && now.timeIntervalSince(hook.updatedAt) < 1200 {
                    status = .needsInput
                } else if hook.state == "running" && now.timeIntervalSince(hook.updatedAt) < 180 {
                    status = .running
                } else if hook.state == "error" {
                    status = .error
                } else if hook.state == "canceled" {
                    status = .canceled
                } else if hook.state == "done" {
                    status = .done
                } else {
                    // Skip idle (e.g. SessionStart before any prompt) or expired/unknown states
                    // so they never fabricate false `.done` completion alerts.
                    continue
                }

                results.append(AgentSession(
                    id: "\(agentKey):\(sid)",
                    rawId: sid,
                    kind: kind,
                    title: title,
                    project: project.isEmpty ? kind.displayName : project,
                    cwd: path,
                    isCLI: false,
                    status: status,
                    currentAction: status == .needsInput
                        ? (hook.action.isEmpty ? "等待你的审批或回复" : hook.action)
                        : (status == .running
                            ? (hook.action.isEmpty ? "执行中…" : hook.action)
                            : (status == .error ? hook.action : "已完成")),
                    detailSummary: "",
                    startedAt: hook.turnStartedAt,
                    updatedAt: hook.updatedAt,
                    completedAt: (status == .running || status == .needsInput) ? nil : (hook.completedAt ?? hook.updatedAt),
                    durationSec: hook.durationSec,
                    activeSubagents: 0,
                    isUnread: false
                ))
            }
        }
        return results
    }
}
