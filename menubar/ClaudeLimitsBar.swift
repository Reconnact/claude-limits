import AppKit
import SwiftUI
import WebKit

struct Window: Decodable { let used_percentage: Double; let resets_at: Double }
struct Snapshot: Decodable { let ts: Double; let five_hour: Window?; let seven_day: Window?; let fable: Window? }

let dir = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_DIR"] ?? "/Users/Shared/claude-limits"
// every account's file; the old app's history and the index are no live value
let skip: Set = ["sources.js", "usage-for-claude.js"]
func rgb(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
// resolved each time it is drawn, so the colours follow the system's light and dark
func themed(_ light: Int, _ dark: Int) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
}
let limits: [(id: String, name: String, key: KeyPath<Snapshot, Window?>, length: Double, color: NSColor)] = [
    ("five_hour", "5 h", \.five_hour, 5 * 3600, themed(0x1f6fe0, 0x3b8eff)),
    ("seven_day", "7 d", \.seven_day, 7 * 86400, themed(0x8b3fd9, 0xba66ff)),
    ("fable", "Fable", \.fable, 7 * 86400, themed(0xb35f0a, 0xe9973f)),
]
let warnColor = themed(0x8f8a14, 0xe0de71)

// flat keys, so Claude can edit the file by hand; a missing or bad key falls back on its own
struct Settings: Codable, Equatable {
    var menuBarLimit = "five_hour"
    var menuBarIcon = "pie"
    var menuBarText = "none"
    var resetFormat = "time"
    var chartLine = "steps"
    var theme = "system"
    var panelLimits = limits.map(\.id)
    var warnAt = 80
    var refreshSeconds = 60

    static let path = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_SETTINGS"]
        ?? NSString(string: "~/.config/claude-limits/settings.json").expandingTildeInPath

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func pick(_ key: CodingKeys, _ allowed: [String]) -> String? {
            (try? c.decode(String.self, forKey: key)).flatMap { allowed.contains($0) ? $0 : nil }
        }
        menuBarLimit = pick(.menuBarLimit, limits.map(\.id) + ["highest"]) ?? menuBarLimit
        menuBarIcon = pick(.menuBarIcon, ["pie", "bar", "none"]) ?? menuBarIcon
        menuBarText = pick(.menuBarText, ["none", "percent", "reset", "both"]) ?? menuBarText
        resetFormat = pick(.resetFormat, ["time", "countdown", "both"]) ?? resetFormat
        chartLine = pick(.chartLine, ["steps", "smooth"]) ?? chartLine
        theme = pick(.theme, ["system", "light", "dark"]) ?? theme
        if let ids = try? c.decode([String].self, forKey: .panelLimits) { panelLimits = ids.filter { limits.map(\.id).contains($0) } }
        if let n = try? c.decode(Int.self, forKey: .warnAt), (0...100).contains(n) { warnAt = n }
        if let n = try? c.decode(Int.self, forKey: .refreshSeconds), n >= 10 { refreshSeconds = n }
    }

    static func load() -> Settings {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(atPath: (Settings.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: Settings.path), options: .atomic)
    }
}

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

// as on the page: the newest window and its highest value, so two snapshots in the same second cannot lower it
func window(_ all: [Snapshot], _ key: KeyPath<Snapshot, Window?>, now: Double) -> (pct: Int, resets_at: Double?)? {
    let ws = all.compactMap { $0[keyPath: key] }
    // resets_at moves by a few seconds between responses, a new window by hours
    guard let newest = ws.map(\.resets_at).max(),
          let w = ws.filter({ newest - $0.resets_at <= 60 }).max(by: { $0.used_percentage < $1.used_percentage }) else { return nil }
    return w.resets_at <= now ? (0, nil) : (Int(w.used_percentage.rounded()), w.resets_at)
}

// the limit the menu bar shows; highest is the one closest to full
func shown(_ all: [Snapshot], _ s: Settings, now: Double) -> (pct: Int, resets_at: Double?)? {
    let ws = limits.filter { s.menuBarLimit == "highest" || s.menuBarLimit == $0.id }.compactMap { window(all, $0.key, now: now) }
    return ws.max { $0.pct < $1.pct }
}

// as pace() on the page: the rise over the last hour of the current window in % per hour, from the value held then or from 0 % at its start,
// and when it fills the window if that comes before the reset; none before the window is an hour old
func pace(_ all: [Snapshot], _ key: KeyPath<Snapshot, Window?>, length: Double, now: Double) -> (rate: Double, full: Double?)? {
    let ws = all.compactMap { s in s[keyPath: key].map { (t: s.ts, w: $0) } }
    guard let newest = ws.map(\.w.resets_at).max(), newest > now, now - (newest - length) >= 3600 else { return nil }
    let own = ws.filter { newest - $0.w.resets_at <= 60 }
    let pct = own.map(\.w.used_percentage).max() ?? 0
    let before = own.filter { $0.t <= now - 3600 }
    let base = before.isEmpty ? (t: newest - length, pct: 0.0) : (t: before.map(\.t).max()!, pct: before.map(\.w.used_percentage).max()!)
    let rate = (pct - base.pct) / (now - base.t) * 3600
    let full = rate > 0 ? now + (100 - pct) / rate * 3600 : nil
    return (rate, full.flatMap { $0 < newest ? $0 : nil })
}

func title(_ pct: Int?) -> String { pct.map { "\($0)%" } ?? "–" }

// as until() on the page
func countdown(_ t: Double, now: Double) -> String {
    let min = max(0, Int(((t - now) / 60).rounded(.up)))
    let d = min / 1440, h = min % 1440 / 60, m = min % 60
    if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
    if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
    return "\(m) min"
}

func when(_ t: Double?, _ format: String, now: Double) -> String {
    guard let t else { return "reset" }
    let date = Date(timeIntervalSince1970: t)
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    switch format {
    case "countdown": return "in \(countdown(t, now: now))"
    case "both": return "\(f.string(from: date)) · in \(countdown(t, now: now))"
    default: return f.string(from: date)
    }
}

func resets(_ t: Double?, _ format: String, now: Double) -> String {
    t == nil ? "reset" : "resets \(when(t, format, now: now))"
}

func menuBarTitle(_ all: [Snapshot], _ s: Settings, now: Double) -> String {
    let w = shown(all, s, now: now)
    switch s.menuBarText {
    case "percent": return title(w?.pct)
    case "reset": return w.map { when($0.resets_at, s.resetFormat, now: now) } ?? "–"
    case "both": return w.map { "\($0.pct)% · \(when($0.resets_at, s.resetFormat, now: now))" } ?? "–"
    default: return ""
    }
}

func rows(_ all: [Snapshot], _ s: Settings, now: Double) -> [(pct: Int, elapsed: Double?, text: String, pace: String?, color: NSColor)] {
    s.panelLimits.compactMap { id in
        guard let l = limits.first(where: { $0.id == id }), let w = window(all, l.key, now: now) else { return nil }
        let elapsed = w.resets_at.map { min(1, max(0, (now - ($0 - l.length)) / l.length)) }
        let p = pace(all, l.key, length: l.length, now: now)
        let text = p.map { $0.full.map { "full \(when($0, "time", now: now))" } ?? "\(String(format: "%.1f", $0.rate)) %/h" }
        return (w.pct, elapsed, "\(l.name)\t\(w.pct) %\t\(resets(w.resets_at, s.resetFormat, now: now))", text, l.color)
    }
}

func age(_ all: [Snapshot], now: Double) -> String? {
    guard let ts = all.map(\.ts).max(), now - ts > 30 * 60 else { return nil }
    let min = Int(now - ts) / 60
    return "last snapshot \(min < 120 ? "\(min) min" : "\(min / 60) h") ago"
}

func pie(_ pct: Int?, _ color: NSColor?) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        color?.set()
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
    image.isTemplate = color == nil
    return image
}

func bar(_ pct: Int?, _ color: NSColor?) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
        color?.set()
        let frame = NSRect(x: 1.5, y: 4.5, width: rect.width - 3, height: 7)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 3.5, yRadius: 3.5)
        outline.lineWidth = 1.2
        outline.stroke()
        let filled = NSRect(x: frame.minX, y: frame.minY, width: frame.width * CGFloat(min(pct ?? 0, 100)) / 100, height: frame.height)
        NSBezierPath(roundedRect: filled, xRadius: 3.5, yRadius: 3.5).fill()
        return true
    }
    image.isTemplate = color == nil
    return image
}

// the tick is the share of the window that has passed: a fill past it is faster than the window allows
func meter(_ pct: Int, _ elapsed: Double?, _ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 40, height: 6), flipped: false) { rect in
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        color.setFill()
        let filled = NSRect(x: 0, y: 0, width: rect.width * CGFloat(min(pct, 100)) / 100, height: rect.height)
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
        if let elapsed {
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            NSColor.labelColor.setFill()
            NSRect(x: min(rect.width - 1.5, rect.width * CGFloat(elapsed)), y: 0, width: 1.5, height: rect.height).fill()
        }
        return true
    }
}

// the panel's content; the buttons act on the bar, or on nothing when only rendered
func panelView(_ all: [Snapshot], _ s: Settings, now: Double, target: AnyObject?) -> NSView {
    var views: [NSView] = []
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let rows = rows(all, s, now: now)
    // the pace column starts after the widest reset text, whatever the reset format
    let reset = rows.map { ($0.text.components(separatedBy: "\t").last! as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    let style = NSMutableParagraphStyle()
    style.tabStops = [50, 100, 100 + reset + 16].map { NSTextTab(textAlignment: .left, location: $0) }
    for row in rows {
        let line = row.text + (row.pace.map { "\t" + $0 } ?? "")
        let text = NSTextField(labelWithAttributedString: NSAttributedString(string: line, attributes: [.font: font, .paragraphStyle: style]))
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        views.append(NSStackView(views: [NSImageView(image: meter(row.pct, row.elapsed, row.color)), text]))
    }
    if let age = age(all, now: now) {
        let label = NSTextField(labelWithString: age)
        label.textColor = .secondaryLabelColor
        views.append(label)
    }
    if views.isEmpty { views.append(NSTextField(labelWithString: "no data yet")) }
    let open = NSButton(title: "Open page", image: NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: nil)!,
                        target: target, action: #selector(Bar.open))
    open.keyEquivalent = "o"
    open.keyEquivalentModifierMask = .command
    let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                            target: target, action: #selector(Bar.openSettings))
    settings.keyEquivalent = ","
    settings.keyEquivalentModifierMask = .command
    let quit = NSButton(title: "", target: NSApp, action: #selector(NSApplication.terminate(_:)))
    quit.isBordered = false
    quit.attributedTitle = NSAttributedString(string: "Quit", attributes: [.foregroundColor: NSColor.systemRed])
    quit.keyEquivalent = "q"
    quit.keyEquivalentModifierMask = .command
    let buttons = NSStackView(views: [open, settings, NSView(), quit])
    views.append(buttons)
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    return stack
}

let now = Date().timeIntervalSince1970
if CommandLine.arguments.contains("--print") {
    print(title(shown(snapshots(), Settings.load(), now: now)?.pct))
    exit(0)
}
if CommandLine.arguments.contains("--title") {
    print(menuBarTitle(snapshots(), Settings.load(), now: now))
    exit(0)
}
if CommandLine.arguments.contains("--menu") {
    let all = snapshots()
    rows(all, Settings.load(), now: now).forEach { print($0.text + ($0.pace.map { "\t" + $0 } ?? "")) }
    age(all, now: now).map { print($0) }
    exit(0)
}
// the panel as a PNG, to look at it without a click; dark, as the popover in dark mode
if let i = CommandLine.arguments.firstIndex(of: "--panel"), i + 1 < CommandLine.arguments.count {
    let view = panelView(snapshots(), Settings.load(), now: now, target: nil)
    view.appearance = NSAppearance(named: .darkAqua)
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let page = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("index.html")

// the app has no menu bar to carry ⌘W, ⌘Q and ⌘,; ⌘Q only closes the window, Quit in the panel ends the app
final class PageWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        if ["w", "q"].contains(event.charactersIgnoringModifiers) {
            performClose(nil)
            return true
        }
        if event.charactersIgnoringModifiers == "," {
            bar.openSettings()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// the window saves every change at once; a change to the file from outside, Claude's included, shows up here too
final class Store: ObservableObject {
    @Published var settings = Settings.load() {
        didSet {
            if !fromFile { settings.save() }
            changed()
        }
    }
    var changed: () -> Void = {}
    private var fromFile = false

    func reload() {
        let s = Settings.load()
        guard s != settings else { return }
        fromFile = true
        settings = s
        fromFile = false
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store

    func panelRow(_ id: String) -> Binding<Bool> {
        Binding(get: { store.settings.panelLimits.contains(id) },
                set: { on in
                    store.settings.panelLimits.removeAll { $0 == id }
                    if on { store.settings.panelLimits.append(id) }
                })
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Limit", selection: $store.settings.menuBarLimit) {
                    ForEach(limits, id: \.id) { Text($0.name).tag($0.id) }
                    Text("Highest").tag("highest")
                }
                Picker("Icon", selection: $store.settings.menuBarIcon) {
                    Text("Pie").tag("pie")
                    Text("Bar").tag("bar")
                    Text("None").tag("none")
                }
                Picker("Text", selection: $store.settings.menuBarText) {
                    Text("None").tag("none")
                    Text("Percent").tag("percent")
                    Text("Reset").tag("reset")
                    Text("Percent and reset").tag("both")
                }
                Stepper(store.settings.warnAt == 0 ? "Never turn yellow" : "Yellow from \(store.settings.warnAt) %",
                        value: $store.settings.warnAt, in: 0...100, step: 5)
            }
            Section("Reset") {
                Picker("Show", selection: $store.settings.resetFormat) {
                    Text("Time").tag("time")
                    Text("Time left").tag("countdown")
                    Text("Both").tag("both")
                }
                .pickerStyle(.segmented)
            }
            Section("Page") {
                Picker("Chart line", selection: $store.settings.chartLine) {
                    Text("Steps").tag("steps")
                    Text("Smooth").tag("smooth")
                }
                .pickerStyle(.segmented)
                Picker("Theme", selection: $store.settings.theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section("Panel") {
                ForEach(limits, id: \.id) { Toggle($0.name, isOn: panelRow($0.id)) }
            }
            Section {
                Stepper("Re-read the data every \(store.settings.refreshSeconds) s",
                        value: $store.settings.refreshSeconds, in: 10...600, step: 10)
                Text(Settings.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}

final class Bar: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let panel = NSViewController()
    let store = Store()
    var lastRefresh = 0.0

    lazy var pageWindow: NSWindow = {
        let window = PageWindow(contentRect: .zero,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "claude-limits"
        window.contentView = WKWebView()
        window.isReleasedWhenClosed = false
        return window
    }()

    lazy var settingsWindow: NSWindow = {
        let window = PageWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
        window.styleMask = [.titled, .closable]
        // unsized until shown, so center() would pin it by its top edge
        window.setContentSize(window.contentViewController!.view.fittingSize)
        window.title = "claude-limits settings"
        window.isReleasedWhenClosed = false
        return window
    }()

    override init() {
        super.init()
        popover.behavior = .transient
        // the spring grows the panel from a dot over half a second
        popover.animates = false
        popover.contentViewController = panel
        // transient alone misses some clicks in other apps
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.popover.performClose(nil) }
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: .leftMouseDown)
        item.button?.imagePosition = .imageLeading
        store.changed = { [weak self] in self?.refresh(); self?.applySettings() }
        refresh()
        applySettings()
        // ⌘Tab and the Dock list the app only while one of its windows is open
        for window in [pageWindow, settingsWindow] {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                let other = window === pageWindow ? settingsWindow : pageWindow
                if !other.isVisible && !other.isMiniaturized { NSApp.setActivationPolicy(.accessory) }
            }
        }
        // the settings file is tiny, so reading it every second is cheaper than watching both the file and its folder
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            store.reload()
            if Date().timeIntervalSince1970 - lastRefresh >= Double(store.settings.refreshSeconds) { refresh() }
        }
    }

    func refresh() {
        let now = Date().timeIntervalSince1970
        lastRefresh = now
        let s = store.settings
        let all = snapshots()
        let pct = shown(all, s, now: now)?.pct
        let color = s.warnAt > 0 && (pct ?? 0) >= s.warnAt ? warnColor : nil
        let text = menuBarTitle(all, s, now: now)
        let icon = s.menuBarIcon == "none" && text.isEmpty ? "pie" : s.menuBarIcon
        item.button?.image = icon == "pie" ? pie(pct, color) : icon == "bar" ? bar(pct, color) : nil
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
        if let color { attributes[.foregroundColor] = color }
        item.button?.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        // built here, not on the click, so the panel opens without the work
        if !popover.isShown {
            panel.view = content()
            panel.preferredContentSize = panel.view.fittingSize
        }
    }

    // per window, not NSApp.appearance, so the menu bar item keeps the menu bar's look
    func applySettings() {
        let s = store.settings
        let appearance = s.theme == "light" ? NSAppearance(named: .aqua) : s.theme == "dark" ? NSAppearance(named: .darkAqua) : nil
        popover.appearance = appearance
        settingsWindow.appearance = appearance
        pageWindow.appearance = appearance
        if pageWindow.isVisible, (pageWindow.contentView as? WKWebView)?.url != pageURL { loadPage() }
    }

    func content() -> NSView {
        panelView(snapshots(), store.settings, now: Date().timeIntervalSince1970, target: self)
    }

    // unfocused the panel is see-through; activating the app to focus it also raises the page window
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.view.window?.styleMask.insert(.nonactivatingPanel)
        panel.view.window?.makeKey()
        refresh()
    }

    // the page cannot read ~/.config, so the settings come along as ?reset=, ?line= and ?theme=
    var pageURL: URL {
        URL(string: "?reset=\(store.settings.resetFormat)&line=\(store.settings.chartLine)&theme=\(store.settings.theme)", relativeTo: page)!.absoluteURL
    }

    // the page loads the data files from /Users/Shared as scripts, outside the repo
    func loadPage() {
        let url = pageURL
        // the reused web view would serve the data scripts from its memory cache, even after they changed
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {
            (self.pageWindow.contentView as? WKWebView)?.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
    }

    @objc func open() {
        popover.performClose(nil)
        loadPage()
        if !pageWindow.isVisible {
            pageWindow.setContentSize(NSSize(width: 900, height: 700))
            pageWindow.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        pageWindow.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        popover.performClose(nil)
        if !settingsWindow.isVisible { settingsWindow.center() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.run()
