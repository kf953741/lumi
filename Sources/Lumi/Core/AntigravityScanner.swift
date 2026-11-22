import Foundation

final class AntigravityScanner: @unchecked Sendable {
    private let dbPath: String
    private var lastKnownSessions: [AgentSession] = []

    private struct DBConversation {
        let id: String
        let title: String
        let preview: String
        let status: String
        let source: String
        let workspaceURIs: String
        let nestingDepth: Int
        let parentId: String
        let notFullyIdle: Bool
        let lastModified: Date
        let lastUserInput: Date?
    }

    private let isoFracFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let isoBasicFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        self.dbPath = "\(NSHomeDirectory())/.gemini/antigravity/conversation_summaries.db"
    }

    func scan(lookbackHours: Double = 24) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            lastKnownSessions = []
            return []
        }
        let now = Date()
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        guard let (dbRows, parentTable) = loadDBRowsAndParents() else {
            // Preserve last known sessions on transient SQLite lock/error instead of wiping UI
            return lastKnownSessions
        }
        let hookMap = LiveHookRecord.loadAll(forAgent: "antigravity")

        var byId: [String: DBConversation] = [:]
        for row in dbRows { byId[row.id] = row }

        // Roll up active child subagents onto their root parent conversation
        var activeSubagents: [String: Int] = [:]
        var activeSubagentAction: [String: (Date, String)] = [:]
        for row in dbRows {
            let explicitParent = !row.parentId.isEmpty ? row.parentId : (parentTable[row.id] ?? "")
            guard !explicitParent.isEmpty || row.nestingDepth > 0 else { continue }
            let hook = hookMap[row.id]
            let isRunning = row.status == "CASCADE_RUN_STATUS_RUNNING"
                || row.notFullyIdle
                || (hook?.state == "running" && now.timeIntervalSince(hook?.updatedAt ?? .distantPast) < 45)
            guard isRunning else { continue }

            var cur = explicitParent
            var hops = 0
            while !cur.isEmpty && hops < 6 {
                let next = byId[cur]?.parentId.isEmpty == false ? byId[cur]!.parentId : (parentTable[cur] ?? "")
                if !next.isEmpty { cur = next } else { break }
                hops += 1
            }
            if !cur.isEmpty {
                activeSubagents[cur, default: 0] += 1
                if let hook, hook.state == "running", !hook.action.isEmpty,
                   now.timeIntervalSince(hook.updatedAt) < 120 {
                    if let existing = activeSubagentAction[cur] {
                        if hook.updatedAt > existing.0 {
                            activeSubagentAction[cur] = (hook.updatedAt, hook.action)
                        }
                    } else {
                        activeSubagentAction[cur] = (hook.updatedAt, hook.action)
                    }
                }
            }
        }

        var results: [AgentSession] = []

        for row in dbRows {
            // Strictly exclude ALL child subagents (both via nesting_depth/parent_conversation_id AND conversation_parents table)
            if row.nestingDepth > 0 || !row.parentId.isEmpty || parentTable[row.id] != nil {
                continue
            }
            let subCount = activeSubagents[row.id] ?? 0
            let dbSaysRunning = (row.status == "CASCADE_RUN_STATUS_RUNNING") || row.notFullyIdle || (subCount > 0)
            guard row.lastModified >= cutoff || dbSaysRunning else { continue }
            let session = buildSession(
                db: row,
                hook: hookMap[row.id],
                subCount: subCount,
                subAction: activeSubagentAction[row.id]?.1,
                now: now
            )
            results.append(session)
        }

        // NOTE: Do NOT emit hook-only Antigravity sessions absent from conversation_summaries.db.
        // Subagents and ephemeral helpers fire hooks before DB checkpointing; waiting for the verified
        // top-level DB row (nesting_depth == 0) guarantees subagents never leak as fake completions.
        lastKnownSessions = results
        return results
    }

    private func buildSession(db: DBConversation, hook: LiveHookRecord?, subCount: Int, subAction: String?, now: Date) -> AgentSession {
        let isCLI = db.source.contains("CLI")
        let wsPath = parseFirstWorkspaceURI(db.workspaceURIs)
            ?? hook?.workspacePaths.first
            ?? hook?.cwd
            ?? ""
        let project = ProjectNameHelper.projectName(from: wsPath)

        let rawTitle: String
        if !db.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTitle = db.title
        } else if !db.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawTitle = db.preview
        } else if let h = hook, !h.firstUserInput.isEmpty {
            rawTitle = h.firstUserInput
        } else if let h = hook, !h.lastUserInput.isEmpty {
            rawTitle = h.lastUserInput
        } else {
            rawTitle = project.isEmpty ? "对话 \(db.id.prefix(6))" : project
        }
        let cleanTitle = ProjectNameHelper.cleanOneLine(rawTitle, maxLength: 78)

        let dbSaysRunning = (db.status == "CASCADE_RUN_STATUS_RUNNING") || db.notFullyIdle || (subCount > 0)
        let hookFresher = hook.map { $0.updatedAt.timeIntervalSince(db.lastModified) > 1.5 } ?? false
        let hookRunningRecent = hook.map { $0.state == "running" && now.timeIntervalSince($0.updatedAt) < 300 } ?? false

        // DB truth for "still running" ALWAYS wins: never let an interim Stop hook mark a
        // conversation as done while Antigravity's DB still reports RUNNING or not_fully_idle.
        let status: SessionStatus
        if dbSaysRunning {
            status = .running
        } else if hookRunningRecent && hookFresher {
            status = .running
        } else if let hook, hook.state == "error" && abs(hook.updatedAt.timeIntervalSince(db.lastModified)) < 30 {
            status = .error
        } else if let hook, hook.state == "canceled" && abs(hook.updatedAt.timeIntervalSince(db.lastModified)) < 30 {
            status = .canceled
        } else {
            status = .done
        }

        let action: String
        if status == .running {
            if let hook, !hook.action.isEmpty, hook.state == "running", now.timeIntervalSince(hook.updatedAt) < 120 {
                action = hook.action
            } else if let subAction, !subAction.isEmpty {
                action = "子任务 · \(subAction)"
            } else if subCount > 0 {
                action = "等待 \(subCount) 个子 Agent 执行…"
            } else if db.notFullyIdle && db.status != "CASCADE_RUN_STATUS_RUNNING" {
                action = "后台任务运行中…"
            } else {
                action = "思考与执行中…"
            }
        } else if status == .error {
            action = hook?.action.isEmpty == false ? (hook?.action ?? "执行出错") : "执行出错"
        } else if status == .canceled {
            action = "已手动停止"
        } else {
            action = "已完成"
        }

        let updatedAt = max(db.lastModified, hook?.updatedAt ?? .distantPast)
        let startedAt: Date? = hook?.turnStartedAt ?? db.lastUserInput
        let completedAt: Date?
        if status == .running {
            completedAt = nil
        } else if let hc = hook?.completedAt, abs(hc.timeIntervalSince(db.lastModified)) < 45 {
            completedAt = max(hc, db.lastModified)
        } else {
            completedAt = db.lastModified
        }

        var durationSec: TimeInterval? = hook?.durationSec
        if durationSec == nil, let comp = completedAt, let start = db.lastUserInput {
            let diff = comp.timeIntervalSince(start)
            if diff >= 1 && diff < 14_400 { durationSec = diff }
        }

        return AgentSession(
            id: "antigravity:\(db.id)",
            rawId: db.id,
            kind: .antigravity,
            title: cleanTitle,
            project: project.isEmpty ? "独立对话" : project,
            cwd: wsPath,
            isCLI: isCLI,
            status: status,
            currentAction: action,
            detailSummary: "",
            startedAt: startedAt,
            updatedAt: updatedAt,
            completedAt: completedAt,
            durationSec: durationSec,
            activeSubagents: subCount,
            isUnread: false
        )
    }

    private func loadDBRowsAndParents() -> ([DBConversation], [String: String])? {
        guard let reader = SQLiteReader(path: dbPath) else { return nil }

        var parentMap: [String: String] = [:]
        _ = reader.query("SELECT conversation_id, parent_id FROM conversation_parents;") { stmt in
            let cid = SQLiteReader.string(stmt, 0)
            let pid = SQLiteReader.string(stmt, 1)
            if !cid.isEmpty && !pid.isEmpty { parentMap[cid] = pid }
        }

        var rows: [DBConversation] = []
        let sql = """
        SELECT conversation_id, title, preview, status, source, workspace_uris,
               nesting_depth, parent_conversation_id, not_fully_idle,
               last_modified_time, last_user_input_time
        FROM conversation_summaries
        WHERE killed = 0
        ORDER BY (status = 'CASCADE_RUN_STATUS_RUNNING' OR not_fully_idle != 0) DESC,
                 last_modified_time DESC
        LIMIT 160;
        """
        let ok = reader.query(sql) { stmt in
            let id = SQLiteReader.string(stmt, 0)
            guard !id.isEmpty else { return }
            rows.append(DBConversation(
                id: id,
                title: SQLiteReader.string(stmt, 1),
                preview: SQLiteReader.string(stmt, 2),
                status: SQLiteReader.string(stmt, 3),
                source: SQLiteReader.string(stmt, 4),
                workspaceURIs: SQLiteReader.string(stmt, 5),
                nestingDepth: SQLiteReader.int(stmt, 6),
                parentId: SQLiteReader.string(stmt, 7),
                notFullyIdle: SQLiteReader.int(stmt, 8) != 0,
                lastModified: parseSQLiteDate(SQLiteReader.string(stmt, 9)) ?? .distantPast,
                lastUserInput: parseSQLiteDate(SQLiteReader.string(stmt, 10))
            ))
        }
        guard ok else { return nil }
        return (rows, parentMap)
    }

    private func parseFirstWorkspaceURI(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = arr.first, !first.isEmpty {
            return first
        }
        return trimmed
    }

    private func parseSQLiteDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        var normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let dotRange = normalized.range(of: ".") {
            let afterDot = normalized[dotRange.upperBound...]
            var tzStart = afterDot.endIndex
            for idx in afterDot.indices {
                let ch = afterDot[idx]
                if ch == "+" || ch == "-" || ch == "Z" {
                    tzStart = idx
                    break
                }
            }
            let frac = String(afterDot[..<tzStart])
            let tz = String(afterDot[tzStart...])
            let frac3 = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized = String(normalized[..<dotRange.lowerBound]) + "." + frac3 + tz
        }
        if let d = isoFracFormatter.date(from: normalized) { return d }
        return isoBasicFormatter.date(from: normalized)
    }
}
