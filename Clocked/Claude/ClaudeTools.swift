import Foundation

struct ToolProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The tools Claude can call, and what each does to the store. Writes go through
/// `ClaudeActivity` so they can be shown and undone; there are no tools that delete.
@MainActor
final class ClaudeTools {
    private let store: TimeStore
    private let prefs: Preferences
    private let activity: ClaudeActivity

    init(store: TimeStore, prefs: Preferences, activity: ClaudeActivity) {
        self.store = store
        self.prefs = prefs
        self.activity = activity
    }

    private static let readTools: Set<String> = ["list_companies", "get_status", "list_sessions", "get_summary"]

    // MARK: Definitions

    /// The tools to offer. The writing ones only while Claude is allowed to change time.
    var definitions: [[String: Any]] {
        Self.all.filter { prefs.claudeCanWrite || Self.readTools.contains($0["name"] as? String ?? "") }
    }

    private static let company: [String: Any] = ["type": "string", "description": "Company name (or part of it), or its id."]
    private static let day: [String: Any] = ["type": "string", "description": "A day: YYYY-MM-DD, \"today\" or \"yesterday\". Defaults to today."]
    private static let time: [String: Any] = ["type": "string", "description": "A time on `day`, like \"09:00\" or \"2:30 PM\", or a full ISO 8601 date and time."]
    private static let note: [String: Any] = ["type": "string", "description": "What the time was spent on."]

    private static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [], readOnly: Bool) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
        ]
    }

    private static let all: [[String: Any]] = [
        tool("list_companies", "List companies", "The companies time is tracked for, with today's time and whether each timer is running.", readOnly: true),
        tool("get_status", "Get status", "Running timers, today's actual and billed time per company, and how billed time is rounded.", readOnly: true),
        tool("list_sessions", "List sessions", "Sessions and adjustments day by day, with notes. Use for summaries, timesheets and invoices.", [
            "company": company,
            "from": ["type": "string", "description": "First day, YYYY-MM-DD. Defaults to today."],
            "to": ["type": "string", "description": "Last day, YYYY-MM-DD, included. Defaults to `from`."],
        ], readOnly: true),
        tool("get_summary", "Get summary", "Actual and billed (rounded) time per day and in total, for a company or all of them, over a range of days.", [
            "company": company,
            "from": ["type": "string", "description": "First day, YYYY-MM-DD. Defaults to today."],
            "to": ["type": "string", "description": "Last day, YYYY-MM-DD, included. Defaults to `from`."],
        ], readOnly: true),
        tool("start_timer", "Start timer", "Starts a company's timer now. Other companies' timers keep running.", [
            "company": company, "note": note,
        ], required: ["company"], readOnly: false),
        tool("stop_timer", "Stop timer", "Stops a company's timer, or every running timer when no company is given.", [
            "company": company,
        ], readOnly: false),
        tool("add_session", "Add session", "Adds finished time with a start and an end.", [
            "company": company, "day": day, "start": time, "end": time, "note": note,
        ], required: ["company", "start", "end"], readOnly: false),
        tool("add_time", "Add time", "Adds finished time when only its length is known. It goes right after the day's last session, or at 9:00 on an empty day.", [
            "company": company, "day": day,
            "minutes": ["type": "integer", "description": "How long, in minutes.", "minimum": 1],
            "note": note,
        ], required: ["company", "minutes"], readOnly: false),
        tool("adjust_day", "Adjust day", "Adds time to a day, or takes it off, without changing its sessions. For time that has no start or end.", [
            "company": company, "day": day,
            "minutes": ["type": "integer", "description": "Minutes to add, or negative to take off."],
            "note": note,
        ], required: ["company", "minutes"], readOnly: false),
        tool("update_session", "Update session", "Changes a session's start, end or note. Get session ids from list_sessions. A running session's end can't be set; stop its timer instead.", [
            "session_id": ["type": "string"],
            "start": ["type": "string", "description": "New start: a time on the session's day, or a full ISO 8601 date and time."],
            "end": ["type": "string", "description": "New end, the same way."],
            "note": note,
        ], required: ["session_id"], readOnly: false),
    ]

    // MARK: Calling

    /// Runs a tool. Nil if there's no tool by that name.
    func call(_ name: String, _ args: [String: Any]) -> Result<Any, ToolProblem>? {
        let run: (([String: Any]) throws -> Any)? = switch name {
        case "list_companies": listCompanies
        case "get_status": status
        case "list_sessions": listSessions
        case "get_summary": summary
        case "start_timer": startTimer
        case "stop_timer": stopTimer
        case "add_session": addSession
        case "add_time": addTime
        case "adjust_day": adjustDay
        case "update_session": updateSession
        default: nil
        }
        guard let run else { return nil }
        activity.touch()
        do {
            if !Self.readTools.contains(name) { try checkWritable() }
            return .success(try run(args))
        } catch let problem as ToolProblem {
            return .failure(problem)
        } catch {
            return .failure(ToolProblem(error.localizedDescription))
        }
    }

    private func checkWritable() throws {
        guard prefs.claudeCanWrite else {
            throw ToolProblem("Changing time is turned off in Clocked's Preferences, under Claude. You can still read time.")
        }
        guard !store.isTestDrive else {
            throw ToolProblem("Clocked is in Test drive, showing sample data. Turn off Test drive in Preferences to change your own time.")
        }
    }

    // MARK: Reading

    private func listCompanies(_ args: [String: Any]) throws -> Any {
        store.companies.map { company in
            [
                "id": company.id.uuidString,
                "name": company.name,
                "running": store.running(for: company.id) != nil,
                "today": TimeFormat.clock(store.actualTotal(for: company.id, on: store.currentDay(for: company.id))),
            ] as [String: Any]
        }
    }

    private func status(_ args: [String: Any]) throws -> Any {
        let today = store.startOfDay(store.now)
        let running = store.runningSessions.map { session -> [String: Any] in
            [
                "company": store.company(session.companyID)?.name ?? "",
                "session_id": session.id.uuidString,
                "started": iso(session.start),
                "elapsed": TimeFormat.clock(session.duration(now: store.now)),
                "note": session.note,
            ]
        }
        let todayTotals = store.companies.compactMap { company -> [String: Any]? in
            let actual = store.actualTotal(for: company.id, on: today)
            guard actual > 0 else { return nil }
            return ["company": company.name, "actual": TimeFormat.clock(actual), "billed": TimeFormat.clock(prefs.rule.apply(actual))]
        }
        var result: [String: Any] = [
            "now": iso(store.now),
            "running": running,
            "today": todayTotals,
            "rounding": roundingDescription,
        ]
        if store.isTestDrive { result["test_drive"] = "Clocked is showing sample data; changes are turned off." }
        return result
    }

    private var roundingDescription: String {
        let rule = prefs.rule
        guard rule.enabled else { return "Off: billed time is the actual time." }
        let after = rule.roundUpAfterMinutes == 0 ? "any leftover time" : "anything over \(TimeFormat.unitName(rule.roundUpAfterMinutes))"
        return "Each day's total per company rounds to whole units of \(TimeFormat.unitName(rule.unitMinutes)); \(after) rounds up to the next unit."
    }

    private func listSessions(_ args: [String: Any]) throws -> Any {
        let companies = try companies(args["company"])
        let (from, to) = try range(args)
        var days: [[String: Any]] = []
        var day = from
        var count = 0
        while day <= to {
            for company in companies {
                let sessions = store.sessions(for: company.id, on: day)
                let adjustments = store.adjustments(for: company.id, on: day)
                guard !sessions.isEmpty || !adjustments.isEmpty else { continue }
                count += sessions.count
                if count > 500 { throw ToolProblem("That's more than 500 sessions. Ask for fewer days.") }
                days.append([
                    "day": dayString(day),
                    "company": company.name,
                    "actual": TimeFormat.clock(store.actualTotal(for: company.id, on: day)),
                    "billed": TimeFormat.clock(prefs.rule.apply(store.actualTotal(for: company.id, on: day))),
                    "sessions": sessions.map(describe),
                    "adjustments": adjustments.map(describe),
                ])
            }
            day = next(day)
        }
        return ["from": dayString(from), "to": dayString(to), "days": days]
    }

    private func summary(_ args: [String: Any]) throws -> Any {
        let companies = try companies(args["company"])
        let (from, to) = try range(args)
        let rows = companies.compactMap { company -> [String: Any]? in
            let totals = store.dailyTotals(for: company.id).filter { $0.key >= from && $0.key <= to && $0.value > 0 }
            guard !totals.isEmpty else { return nil }
            let actual = totals.values.reduce(0, +)
            let billed = totals.values.reduce(0) { $0 + prefs.rule.apply($1) }
            return [
                "company": company.name,
                "actual": TimeFormat.clock(actual),
                "billed": TimeFormat.clock(billed),
                "actual_minutes": Int(actual / 60),
                "billed_minutes": Int(billed / 60),
                "days": totals.keys.sorted().map { day in
                    ["day": dayString(day), "actual": TimeFormat.clock(totals[day]!), "billed": TimeFormat.clock(prefs.rule.apply(totals[day]!))]
                },
            ]
        }
        return ["from": dayString(from), "to": dayString(to), "rounding": roundingDescription, "companies": rows]
    }

    // MARK: Writing

    private func startTimer(_ args: [String: Any]) throws -> Any {
        let company = try company(args["company"])
        if let running = store.running(for: company.id) {
            return ["already_running": true, "session": describe(running)]
        }
        guard let session = store.start(company.id, source: .assistant) else { throw ToolProblem("Couldn't start the timer.") }
        if let note = args["note"] as? String, !note.isEmpty { store.setNote(note, for: session.id) }
        activity.record([.session(id: session.id, before: nil)])
        return ["started": describe(store.session(session.id) ?? session)]
    }

    private func stopTimer(_ args: [String: Any]) throws -> Any {
        let running = try args["company"] == nil
            ? store.runningSessions
            : store.running(for: company(args["company"]).id).map { [$0] } ?? []
        guard !running.isEmpty else { return ["stopped": [], "message": "No timer was running."] }
        var stopped: [Session] = []
        for before in running {
            if let session = store.stop(before.companyID) { stopped.append(session) }
        }
        activity.record(zip(running, stopped).map { .session(id: $1.id, before: $0) })
        return ["stopped": stopped.map(describe)]
    }

    private func addSession(_ args: [String: Any]) throws -> Any {
        let company = try company(args["company"])
        let day = try parseDay(args["day"])
        let start = try parseTime(args["start"], on: day, name: "start")
        var end = try parseTime(args["end"], on: day, name: "end")
        // "11 PM to 1 AM" runs past midnight.
        if end <= start, let raw = args["end"] as? String, !raw.contains("T") {
            end = store.calendar.date(byAdding: .day, value: 1, to: end) ?? end
        }
        guard end <= Date().addingTimeInterval(60) else { throw ToolProblem("The end is in the future. Start a timer for time that's still going.") }
        if let problem = store.problem(withTimes: start, end, for: company.id, excluding: nil) { throw ToolProblem(problem) }
        let session = store.addSession(companyID: company.id, start: start, end: end, note: trimmedNote(args), source: .assistant)
        activity.record([.session(id: session.id, before: nil)])
        return ["added": describe(session)]
    }

    private func addTime(_ args: [String: Any]) throws -> Any {
        let company = try company(args["company"])
        let day = try parseDay(args["day"])
        guard let minutes = int(args["minutes"]), minutes > 0 else { throw ToolProblem("minutes has to be a whole number above 0.") }
        let start = store.nextFreeStart(companyID: company.id, day: day)
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        if end > Date().addingTimeInterval(60) || store.problem(withTimes: start, end, for: company.id, excluding: nil) != nil {
            throw ToolProblem("There's no room for \(TimeFormat.duration(end.timeIntervalSince(start))) after that day's last session without running into the future or a running timer. Use add_session with times, or adjust_day.")
        }
        guard let session = store.addEntry(companyID: company.id, day: day, seconds: TimeInterval(minutes * 60), note: trimmedNote(args), source: .assistant) else {
            throw ToolProblem("Couldn't add the time.")
        }
        activity.record([.session(id: session.id, before: nil)])
        return ["added": describe(session)]
    }

    private func adjustDay(_ args: [String: Any]) throws -> Any {
        let company = try company(args["company"])
        let day = try parseDay(args["day"])
        guard let minutes = int(args["minutes"]), minutes != 0 else { throw ToolProblem("minutes has to be a whole number other than 0.") }
        guard let adjustment = store.addAdjustment(companyID: company.id, day: day, seconds: TimeInterval(minutes * 60), note: trimmedNote(args)) else {
            throw ToolProblem("Couldn't adjust the day.")
        }
        activity.record([.adjustment(id: adjustment.id, before: nil)])
        return ["adjusted": describe(adjustment), "day_total": TimeFormat.clock(store.actualTotal(for: company.id, on: day))]
    }

    private func updateSession(_ args: [String: Any]) throws -> Any {
        guard let idString = args["session_id"] as? String, let id = UUID(uuidString: idString), let before = store.session(id) else {
            throw ToolProblem("There's no session with that id. Use list_sessions to find it.")
        }
        let day = store.startOfDay(before.start)
        let start = try args["start"] == nil ? before.start : parseTime(args["start"], on: day, name: "start")
        if before.isRunning, args["end"] != nil { throw ToolProblem("That session's timer is still running. Use stop_timer to end it.") }
        let end = try args["end"] == nil ? before.end : parseTime(args["end"], on: day, name: "end")
        if start != before.start || end != before.end {
            if let problem = store.problem(withTimes: start, end, for: before.companyID, excluding: id) { throw ToolProblem(problem) }
            store.setTimes(for: id, start: start, end: end)
        }
        if let note = args["note"] as? String { store.setNote(note, for: id) }
        guard let after = store.session(id) else { throw ToolProblem("Couldn't update the session.") }
        if after != before { activity.record([.session(id: id, before: before)]) }
        return ["updated": describe(after)]
    }

    // MARK: Arguments

    private func company(_ value: Any?) throws -> Company {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw ToolProblem("Which company? \(companyList)")
        }
        if let id = UUID(uuidString: text), let company = store.company(id) { return company }
        let query = text.lowercased()
        let names = store.companies.map { ($0, $0.name.lowercased()) }
        for match in [{ $0 == query }, { $0.hasPrefix(query) }, { $0.contains(query) || query.contains($0) }] as [(String) -> Bool] {
            let found = names.filter { match($0.1) }.map(\.0)
            if found.count == 1 { return found[0] }
            if found.count > 1 { throw ToolProblem("\"\(text)\" could be \(found.map(\.name).joined(separator: " or ")). Which one?") }
        }
        throw ToolProblem("There's no company called \"\(text)\". \(companyList)")
    }

    /// One company, or all of them when none is given.
    private func companies(_ value: Any?) throws -> [Company] {
        value == nil ? store.companies : [try company(value)]
    }

    private var companyList: String {
        store.companies.isEmpty ? "There are no companies yet." : "Companies: " + store.companies.map(\.name).joined(separator: ", ") + "."
    }

    private func trimmedNote(_ args: [String: Any]) -> String {
        (args["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double, d == d.rounded() { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func range(_ args: [String: Any]) throws -> (Date, Date) {
        let from = try parseDay(args["from"])
        let to = try args["to"] == nil ? from : parseDay(args["to"])
        guard to >= from else { throw ToolProblem("`to` is before `from`.") }
        guard store.calendar.dateComponents([.day], from: from, to: to).day ?? 0 <= 400 else {
            throw ToolProblem("That's more than 400 days. Ask for a shorter range.")
        }
        return (from, to)
    }

    private func parseDay(_ value: Any?) throws -> Date {
        let today = store.startOfDay(store.now)
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty, text != "today" else { return today }
        if text == "yesterday" { return store.calendar.date(byAdding: .day, value: -1, to: today) ?? today }
        if let date = Self.dayFormatter.date(from: String(text.prefix(10))) { return store.startOfDay(date) }
        throw ToolProblem("Couldn't read the day \"\(text)\". Use YYYY-MM-DD.")
    }

    private func parseTime(_ value: Any?, on day: Date, name: String) throws -> Date {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw ToolProblem("\(name) is missing.")
        }
        if text.contains("T") || text.count > 10 {
            for formatter in [Self.isoFractional, Self.iso] { if let date = formatter.date(from: text) { return date } }
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                Self.localFormatter.dateFormat = format
                if let date = Self.localFormatter.date(from: text) { return date }
            }
        }
        // "9", "09:00", "9:00 am", "2:30PM"
        let pattern = try! Regex<(Substring, Substring, Substring?, Substring?)>(#"(\d{1,2})(?:[:.](\d{2}))?\s*([ap]\.?m\.?)?"#).ignoresCase()
        if let match = try? pattern.wholeMatch(in: text), var hour = Int(match.1) {
            let minute = match.2.flatMap { Int($0) } ?? 0
            if let suffix = match.3?.lowercased() {
                guard (1...12).contains(hour) else { throw ToolProblem("Couldn't read the time \"\(text)\".") }
                hour = hour % 12 + (suffix.hasPrefix("p") ? 12 : 0)
            }
            if (0...23).contains(hour), (0...59).contains(minute),
               let date = store.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) {
                return date
            }
        }
        throw ToolProblem("Couldn't read the time \"\(text)\". Use something like 09:00, 2:30 PM, or a full ISO 8601 date and time.")
    }

    private func next(_ day: Date) -> Date {
        store.calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
    }

    // MARK: Output

    private func describe(_ session: Session) -> [String: Any] {
        [
            "id": session.id.uuidString,
            "company": store.company(session.companyID)?.name ?? "",
            "start": iso(session.start),
            "end": session.end.map(iso) ?? NSNull(),
            "running": session.isRunning,
            "duration": TimeFormat.clock(session.duration(now: store.now)),
            "minutes": Int(session.duration(now: store.now) / 60),
            "note": session.note,
            "source": session.source == .assistant ? "claude" : session.source.rawValue,
        ]
    }

    private func describe(_ adjustment: Adjustment) -> [String: Any] {
        [
            "id": adjustment.id.uuidString,
            "company": store.company(adjustment.companyID)?.name ?? "",
            "day": dayString(adjustment.day),
            "time": TimeFormat.signedClock(adjustment.seconds),
            "minutes": Int(adjustment.seconds / 60),
            "note": adjustment.note,
        ]
    }

    private func iso(_ date: Date) -> String { Self.isoOut.string(from: date) }
    private func dayString(_ date: Date) -> String { Self.dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Local time with its offset, like 2026-11-03T09:00:00-05:00.
    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
}
