import AppKit
import WebKit

struct Window: Decodable { let used_percentage: Double; let resets_at: Double }
struct Snapshot: Decodable { let ts: Double; let five_hour: Window?; let seven_day: Window?; let fable: Window? }

let dir = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_DIR"] ?? "/Users/Shared/claude-limits"
// every account's file; the old app's history and the index are no live value
let skip: Set = ["sources.js", "usage-for-claude.js"]
let limits: [(name: String, key: KeyPath<Snapshot, Window?>, color: NSColor)] = [
    ("5 h", \.five_hour, NSColor(red: 0x3b / 255, green: 0x8e / 255, blue: 0xff / 255, alpha: 1)),
    ("7 d", \.seven_day, NSColor(red: 0xba / 255, green: 0x66 / 255, blue: 0xff / 255, alpha: 1)),
    ("Fable", \.fable, NSColor(red: 0xe9 / 255, green: 0x97 / 255, blue: 0x3f / 255, alpha: 1)),
]

func snapshots() -> [Snapshot] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".js") && !skip.contains($0) }
        .compactMap { try? String(contentsOfFile: "\(dir)/\($0)", encoding: .utf8) }
        .flatMap { $0.split(separator: "\n") }
        .compactMap { line -> Snapshot? in
            let json = line.dropFirst("S.push(".count).dropLast(");".count)
            return try? JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        }
}

// newest snapshot that has this window
func window(_ all: [Snapshot], _ key: KeyPath<Snapshot, Window?>, now: Double) -> (pct: Int, resets_at: Double?)? {
    guard let w = all.filter({ $0[keyPath: key] != nil }).max(by: { $0.ts < $1.ts })?[keyPath: key] else { return nil }
    return w.resets_at <= now ? (0, nil) : (Int(w.used_percentage.rounded()), w.resets_at)
}

func title(_ pct: Int?) -> String { pct.map { "\($0)%" } ?? "–" }

func resets(_ t: Double?) -> String {
    guard let t else { return "reset" }
    let date = Date(timeIntervalSince1970: t)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return "resets \(f.string(from: date))"
}

func rows(_ all: [Snapshot], now: Double) -> [(pct: Int, text: String)?] {
    limits.map { l in window(all, l.key, now: now).map { ($0.pct, "\(l.name)\t\($0.pct) %\t\(resets($0.resets_at))") } }
}

func age(_ all: [Snapshot], now: Double) -> String? {
    guard let ts = all.map(\.ts).max(), now - ts > 30 * 60 else { return nil }
    let min = Int(now - ts) / 60
    return "last snapshot \(min < 120 ? "\(min) min" : "\(min / 60) h") ago"
}

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

func meter(_ pct: Int, _ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 40, height: 6), flipped: false) { rect in
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        color.setFill()
        let filled = NSRect(x: 0, y: 0, width: rect.width * CGFloat(min(pct, 100)) / 100, height: rect.height)
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        return true
    }
}

let now = Date().timeIntervalSince1970
if CommandLine.arguments.contains("--print") {
    print(title(window(snapshots(), \.five_hour, now: now)?.pct))
    exit(0)
}
if CommandLine.arguments.contains("--menu") {
    let all = snapshots()
    rows(all, now: now).compactMap { $0?.text }.forEach { print($0) }
    age(all, now: now).map { print($0) }
    exit(0)
}

let page = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("index.html")

final class Bar: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(show)
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        item.button?.image = pie(window(snapshots(), \.five_hour, now: Date().timeIntervalSince1970)?.pct)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date().timeIntervalSince1970
        let all = snapshots()
        menu.removeAllItems()
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 50), NSTextTab(textAlignment: .left, location: 100)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for (row, l) in zip(rows(all, now: now), limits) {
            guard let row else { continue }
            let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            entry.attributedTitle = NSAttributedString(string: row.text, attributes: [.font: font, .paragraphStyle: style])
            entry.image = meter(row.pct, l.color)
            menu.addItem(entry)
        }
        if let age = age(all, now: now) {
            menu.addItem(NSMenuItem(title: age, action: nil, keyEquivalent: ""))
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "no data yet", action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open page", action: #selector(open), keyEquivalent: "o")
        open.target = self
        open.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: nil)
        menu.addItem(open)
        refresh()
    }

    // centred under the icon; a status item's own menu opens flush left.
    // Starts at the menu bar's lower edge, not the button's: with a notch the bar is taller, and a menu reaching into it scrolls.
    @objc func show() {
        guard let button = item.button else { return }
        let menu = NSMenu()
        menu.delegate = self
        menuNeedsUpdate(menu)
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: icon.midX - menu.size.width / 2, y: screen.visibleFrame.maxY), in: nil)
        button.highlight(false)
    }

    lazy var panel: NSPopover = {
        let controller = NSViewController()
        controller.view = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        return popover
    }()

    // the page loads the data files from /Users/Shared as scripts, outside the repo
    @objc func open() {
        guard let button = item.button, let web = panel.contentViewController?.view as? WKWebView else { return }
        web.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        NSApp.activate()
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.run()
