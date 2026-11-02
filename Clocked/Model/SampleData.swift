import Foundation

/// Sample companies and about ten weeks of time for Test drive, ending in a running timer.
/// Seeded, so every test drive starts from the same believable history.
enum SampleData {
    struct Contents {
        var companies: [Company]
        var sessions: [Session]
        var selectedCompanyID: UUID
    }

    static func make(now: Date, calendar: Calendar) -> Contents {
        var rng = SplitMix64(seed: 2026)
        let acme = Company(name: "Acme Studio", colorIndex: 0)
        let northwind = Company(name: "Northwind", colorIndex: 1)
        let bluebird = Company(name: "Bluebird Labs", colorIndex: 2)
        let freelance = Company(name: "Freelance", colorIndex: 3)
        let today = calendar.startOfDay(for: now)
        var sessions: [Session] = []
        // Notes come from their own generator, so the times stay the same as before notes.
        var noteRNG = SplitMix64(seed: 711)

        func add(_ company: Company, _ day: Date, at minute: Int, for length: Int) {
            guard let start = calendar.date(byAdding: .minute, value: minute, to: day) else { return }
            let choices = notes[company.name] ?? []
            // About one session in six has no note.
            let note = choices.isEmpty || Int.random(in: 0..<6, using: &noteRNG) == 0
                ? "" : choices[Int.random(in: 0..<choices.count, using: &noteRNG)]
            sessions.append(Session(companyID: company.id, start: start, end: start.addingTimeInterval(TimeInterval(length * 60)), note: note))
        }

        for daysBack in 1...75 {
            guard let day = calendar.date(byAdding: .day, value: -daysBack, to: today) else { continue }
            if calendar.isDateInWeekend(day) {
                if Int.random(in: 0..<4, using: &rng) == 0 {
                    add(freelance, day, at: 10 * 60, for: Int.random(in: 40...150, using: &rng))
                }
                continue
            }
            let start = 8 * 60 + Int.random(in: 15...75, using: &rng)
            let morning = Int.random(in: 120...200, using: &rng)
            add(acme, day, at: start, for: morning)
            if Int.random(in: 0..<10, using: &rng) < 4 {
                add(northwind, day, at: 13 * 60, for: Int.random(in: 30...110, using: &rng))
            }
            add(acme, day, at: 15 * 60, for: Int.random(in: 40...180, using: &rng))
            if Int.random(in: 0..<10, using: &rng) < 2 {
                add(bluebird, day, at: 18 * 60 + 30, for: Int.random(in: 30...90, using: &rng))
            }
        }

        // Today: whatever of the usual morning fits before a timer started 1h 22m ago.
        let runningStart = now.addingTimeInterval(-(82 * 60 + 47))
        let minutesBeforeRunning = Int(runningStart.timeIntervalSince(today) / 60)
        for (company, start, length) in [(acme, 9 * 60 + 15, 51), (northwind, 10 * 60 + 30, 65), (freelance, 12 * 60 + 20, 40)]
        where start + length < minutesBeforeRunning - 10 {
            add(company, today, at: start, for: length)
        }
        sessions.sort { $0.start < $1.start }
        sessions.append(Session(companyID: acme.id, start: runningStart, note: "Migrating billing webhooks to v2"))

        return Contents(companies: [acme, northwind, bluebird, freelance], sessions: sessions, selectedCompanyID: acme.id)
    }
}

private let notes: [String: [String]] = [
    "Acme Studio": [
        "Sprint planning, estimates for the reporting work",
        "Auth refactor: token refresh and retry",
        "Client call re: Q1 scope",
        "Reviewed PR #214, left notes on caching",
        "Dashboard charts: empty and loading states",
        "Fixed timezone bug in invoice exports",
        "Pairing with Sam on the import pipeline",
        "Wrote migration for the new billing tables",
    ],
    "Northwind": [
        "Weekly sync and roadmap review",
        "Shipping rates API integration",
        "Bug triage",
        "Onboarding flow copy and layout",
    ],
    "Bluebird Labs": [
        "Prototype for the scheduling screen",
        "Design review with the founders",
    ],
    "Freelance": [
        "Portfolio site updates",
        "Logo revisions for the bakery",
    ],
]

/// Small seeded random number generator.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
