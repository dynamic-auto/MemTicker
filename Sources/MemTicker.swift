import AppKit
import ServiceManagement

// MARK: - Memory reading

struct MemorySample {
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let total: UInt64

    /// Matches Activity Monitor's "Memory Used" = App Memory + Wired + Compressed.
    var used: UInt64 { app + wired + compressed }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryReader {
    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return size > 0 ? UInt64(size) : 4096
    }()

    static let physical: UInt64 = ProcessInfo.processInfo.physicalMemory

    static func sample() -> MemorySample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0

        return MemorySample(
            app: appPages * pageSize,
            wired: UInt64(stats.wire_count) * pageSize,
            compressed: UInt64(stats.compressor_page_count) * pageSize,
            cached: UInt64(stats.external_page_count) * pageSize,
            total: physical
        )
    }
}

// MARK: - Formatting

enum Fmt {
    static let gib = 1024.0 * 1024.0 * 1024.0

    static func gb(_ bytes: UInt64, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", Double(bytes) / gib)
    }

    /// Physical RAM reads nicer as a whole number: "16" rather than "16.00".
    static func totalGB(_ bytes: UInt64) -> String {
        let value = Double(bytes) / gib
        let rounded = value.rounded()
        return abs(value - rounded) < 0.01
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", value)
    }
}

// MARK: - Preferences

enum DisplayStyle: Int, CaseIterable {
    case usedOverTotal = 0
    case usedOnly = 1
    case percent = 2

    var label: String {
        switch self {
        case .usedOverTotal: return "12.50 / 16 GB"
        case .usedOnly:      return "12.50 GB"
        case .percent:       return "78%"
        }
    }

    func render(_ s: MemorySample) -> String {
        switch self {
        case .usedOverTotal:
            return "\(Fmt.gb(s.used)) / \(Fmt.totalGB(s.total)) GB"
        case .usedOnly:
            return "\(Fmt.gb(s.used)) GB"
        case .percent:
            return String(format: "%.0f%%", s.fraction * 100)
        }
    }
}

enum Prefs {
    private static let styleKey = "displayStyle"
    private static let intervalKey = "refreshInterval"

    static var style: DisplayStyle {
        get { DisplayStyle(rawValue: UserDefaults.standard.integer(forKey: styleKey)) ?? .usedOverTotal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    static var interval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return stored > 0 ? stored : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?

    private let appItem        = NSMenuItem(title: "App Memory —", action: nil, keyEquivalent: "")
    private let wiredItem      = NSMenuItem(title: "Wired —", action: nil, keyEquivalent: "")
    private let compressedItem = NSMenuItem(title: "Compressed —", action: nil, keyEquivalent: "")
    private let cachedItem     = NSMenuItem(title: "Cached Files —", action: nil, keyEquivalent: "")

    private let intervals: [TimeInterval] = [1, 2, 5, 10]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .noImage
        statusItem.menu = buildMenu()

        refresh()
        restartTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        for item in [appItem, wiredItem, compressedItem, cachedItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let displayMenu = NSMenu()
        for style in DisplayStyle.allCases {
            let item = NSMenuItem(title: style.label,
                                  action: #selector(setStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = style.rawValue
            item.state = (style == Prefs.style) ? .on : .off
            displayMenu.addItem(item)
        }
        let displayRoot = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        displayRoot.submenu = displayMenu
        menu.addItem(displayRoot)

        let intervalMenu = NSMenu()
        for seconds in intervals {
            let item = NSMenuItem(title: "\(Int(seconds)) second\(seconds == 1 ? "" : "s")",
                                  action: #selector(setInterval(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = Int(seconds)
            item.state = (seconds == Prefs.interval) ? .on : .off
            intervalMenu.addItem(item)
        }
        let intervalRoot = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        intervalRoot.submenu = intervalMenu
        menu.addItem(intervalRoot)

        menu.addItem(.separator())

        let activity = NSMenuItem(title: "Open Activity Monitor",
                                  action: #selector(openActivityMonitor),
                                  keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Start at Login",
                                   action: #selector(toggleLoginItem(_:)),
                                   keyEquivalent: "")
            login.target = self
            login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MemTicker", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        if #available(macOS 13.0, *) {
            menu.items.first { $0.title == "Start at Login" }?
                .state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    // MARK: Updating

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Prefs.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common so it keeps ticking while the menu is open or a window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let sample = MemoryReader.sample() else {
            setTitle("— GB")
            return
        }

        setTitle(Prefs.style.render(sample))

        let total = Fmt.totalGB(sample.total)
        appItem.title        = "App Memory      \(Fmt.gb(sample.app)) GB"
        wiredItem.title      = "Wired           \(Fmt.gb(sample.wired)) GB"
        compressedItem.title = "Compressed      \(Fmt.gb(sample.compressed)) GB"
        cachedItem.title     = "Cached Files    \(Fmt.gb(sample.cached)) GB  (of \(total) GB)"
    }

    private func setTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        // Monospaced digits stop the text jittering as numbers change width.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
    }

    // MARK: Actions

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let style = DisplayStyle(rawValue: sender.tag) else { return }
        Prefs.style = style
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
        refresh()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        Prefs.interval = TimeInterval(sender.tag)
        sender.menu?.items.forEach { $0.state = ($0 === sender) ? .on : .off }
        restartTimer()
        refresh()
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @available(macOS 13.0, *)
    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nThis usually works only once MemTicker is in /Applications."
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
