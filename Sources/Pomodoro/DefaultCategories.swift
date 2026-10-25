import Foundation

/// The categories everyone starts with, so the timesheet groups your work from
/// the first session. They cover general office work, software engineering and
/// sales; any you never use stay out of sight. Each comes with example phrases
/// the classifier matches against — rename, delete or add categories and file
/// tasks to teach it more.
///
/// IDs are stable: a default you renamed keeps its examples.
enum DefaultCategories {
    struct Default {
        var id: String
        var name: String
        var examples: [String]
    }

    /// In this order for colors and the 1–9 keys.
    static let all: [Default] = [
        // Sales
        Default(id: "default.outreach", name: "Prospecting", examples: [
            "cold calling", "cold email", "outbound", "prospecting", "prospect list", "lead gen", "lead list",
            "pipeline", "gifting", "linkedin outreach", "sales calls", "follow up texts", "sequences", "CRM",
            "meetings booked", "SDR", "BDR", "list building", "prospect research", "account research",
        ]),
        Default(id: "default.customers", name: "Customers & deals", examples: [
            "customer call", "client meeting", "demo", "proposal", "RFP response", "account management",
            "customer onboarding", "support tickets", "renewal", "quote", "deal review", "negotiation",
            "pricing", "upsell", "QBR", "discovery call", "closing", "account plan",
        ]),
        // Engineering
        Default(id: "default.coding", name: "Coding", examples: [
            "coding", "programming", "feature", "implement", "refactor", "bug fix", "debugging", "tests",
            "unit tests", "frontend", "backend", "API", "migration", "prototype", "deploy", "CI",
            "infrastructure", "terraform", "build", "ticket", "JIRA", "spike", "investigate", "performance",
            "upgrade", "dependencies", "kubernetes", "docker", "AWS", "database", "SQL", "UI", "iOS", "android",
            "react", "app", "dev environment", "pair programming", "release",
        ]),
        Default(id: "default.review", name: "Code review", examples: [
            "code review", "PR review", "reviewing PRs", "review pull requests", "PR feedback",
        ]),
        Default(id: "default.incidents", name: "Incidents & on-call", examples: [
            "incident", "incident response", "on call", "outage", "pager", "hotfix", "firefighting",
            "postmortem", "production issue", "alerts", "bug triage",
        ]),
        // Office
        Default(id: "default.focus", name: "Docs & analysis", examples: [
            "writing", "docs", "design doc", "spec", "report", "memo", "slide deck", "presentation",
            "spreadsheet", "analysis", "research", "data analysis", "dashboard", "write up", "blog post",
            "notion page", "deep work", "weekly report", "investor update", "market research",
        ]),
        Default(id: "default.planning", name: "Planning", examples: [
            "planning", "weekly review", "close out week", "roadmap", "brainstorming", "strategy",
            "goals", "prioritisation", "prioritization", "OKRs", "sprint planning", "quarterly planning", "backlog grooming", "planning doc",
        ]),
        Default(id: "default.team", name: "Team & meetings", examples: [
            "team meeting", "standup", "stand up", "one on one", "1:1", "all hands", "team sync", "retro",
            "banter with team", "manager check in", "internal meeting", "offsite", "town hall",
            "eng sync", "leadership", "staff meeting", "kickoff",
        ]),
        Default(id: "default.hiring", name: "Hiring", examples: [
            "interview", "recruiting", "candidate", "hiring", "job description", "work trial",
            "offer letter", "reference check", "sourcing candidates", "debrief", "take home",
            "job post", "screening", "onsite",
        ]),
        Default(id: "default.comms", name: "Email & messages", examples: [
            "email", "emails", "slack", "inbox", "messages", "replying", "inbox zero",
            "catch up on messages", "correspondence",
        ]),
        Default(id: "default.admin", name: "Admin", examples: [
            "admin", "expenses", "invoices", "accounting", "legal", "compliance", "GDPR", "visa",
            "office clean up", "buy equipment", "ordering supplies", "IT setup", "paperwork", "timesheet",
            "booking travel", "flights", "hotel", "HR forms", "payroll", "taxes", "insurance",
        ]),
        Default(id: "default.learning", name: "Learning", examples: [
            "learning", "reading", "course", "training", "tutorial", "conference", "webinar",
            "studying", "workshop", "book", "podcast",
        ]),
        Default(id: personalID, name: "Breaks & personal", examples: [
            "break", "lunch", "dinner", "breakfast", "coffee", "exercise", "gym", "walk", "travel",
            "commute", "errands", "doctor", "personal", "nap",
        ]),
    ]

    /// Time that isn't work: listed last and left out of "Top category".
    static let personalID = "default.personal"

    static var examples: [(text: String, categoryID: String)] {
        all.flatMap { category in category.examples.map { ($0, category.id) } }
    }
}
