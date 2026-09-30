import AppKit

struct Window: Decodable { let used_percentage: Double; let resets_at: Double }
struct Snapshot: Decodable { let ts: Double; let five_hour: Window? }

let dir = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_DIR"] ?? "/Users/Shared/claude-limits"
let sources = ["hw", "reconnact"]

func title(now: Double) -> String {
    let newest = sources
        .compactMap { try? String(contentsOfFile: "\(dir)/\($0).js", encoding: .utf8) }
        .flatMap { $0.split(separator: "\n") }
        .compactMap { line -> Snapshot? in
            let json = line.dropFirst("S.push(".count).dropLast(");".count)
            return try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        }
        .filter { $0.five_hour != nil }
        .max { $0.ts < $1.ts }
    guard let w = newest?.five_hour else { return "–" }
    return w.resets_at <= now ? "0%" : "\(Int(w.used_percentage.rounded()))%"
}

if CommandLine.arguments.contains("--print") {
    print(title(now: Date().timeIntervalSince1970))
    exit(0)
}

let page = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("index.html")

final class Bar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(open)
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() { item.button?.title = title(now: Date().timeIntervalSince1970) }

    @objc func open() { NSWorkspace.shared.open(page) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.run()
