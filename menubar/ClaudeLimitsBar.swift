import AppKit

struct Window: Decodable { let used_percentage: Double; let resets_at: Double }
struct Snapshot: Decodable { let ts: Double; let five_hour: Window? }

let dir = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_DIR"] ?? "/Users/Shared/claude-limits"
// every account's file; the old app's history and the index are no live value
let skip: Set = ["sources.js", "usage-for-claude.js"]

func percent(now: Double) -> Int? {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let newest = files.filter { $0.hasSuffix(".js") && !skip.contains($0) }
        .compactMap { try? String(contentsOfFile: "\(dir)/\($0)", encoding: .utf8) }
        .flatMap { $0.split(separator: "\n") }
        .compactMap { line -> Snapshot? in
            let json = line.dropFirst("S.push(".count).dropLast(");".count)
            return try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        }
        .filter { $0.five_hour != nil }
        .max { $0.ts < $1.ts }
    guard let w = newest?.five_hour else { return nil }
    return w.resets_at <= now ? 0 : Int(w.used_percentage.rounded())
}

func title(_ pct: Int?) -> String { pct.map { "\($0)%" } ?? "–" }

func pie(_ pct: Int?) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        let circle = rect.insetBy(dx: 1.5, dy: 1.5)
        let outline = NSBezierPath(ovalIn: circle)
        outline.lineWidth = 1.2
        outline.stroke()
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(withCenter: center, radius: circle.width / 2, startAngle: 90,
                        endAngle: 90 - 3.6 * CGFloat(min(pct ?? 0, 100)), clockwise: true)
        wedge.close()
        wedge.fill()
        return true
    }
    image.isTemplate = true
    return image
}

if CommandLine.arguments.contains("--print") {
    print(title(percent(now: Date().timeIntervalSince1970)))
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

    func refresh() {
        let pct = percent(now: Date().timeIntervalSince1970)
        item.button?.image = pie(pct)
        item.button?.imagePosition = .imageLeading
        item.button?.title = title(pct)
    }

    @objc func open() { NSWorkspace.shared.open(page) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.run()
