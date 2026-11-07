import AppKit
import SwiftUI
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import UserNotifications

// MARK: - Durations

enum AwakeDuration: Int, CaseIterable, Identifiable {
    case min30 = 1800
    case hr1 = 3600
    case hr2 = 7200
    case hr4 = 14400
    case hr8 = 28800
    case indefinite = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .min30: return "30 min"
        case .hr1: return "1 hour"
        case .hr2: return "2 hours"
        case .hr4: return "4 hours"
        case .hr8: return "8 hours"
        case .indefinite: return "No limit"
        }
    }

    /// nil means no timer. STAYAWAKE_TEST_SECONDS shortens every timed option for testing.
    var seconds: TimeInterval? {
        if self == .indefinite { return nil }
        if let raw = ProcessInfo.processInfo.environment["STAYAWAKE_TEST_SECONDS"],
           let test = TimeInterval(raw) {
            return test
        }
        return TimeInterval(rawValue)
    }
}

// MARK: - What macOS does on its own (read from pmset, no privileges)

struct SystemSleepInfo {
    var displayMinutes: Int?
    var sleepMinutes: Int?
    var onBattery = false

    static func read() -> SystemSleepInfo {
        var info = SystemSleepInfo()

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            info.onBattery = (type as String) == kIOPMBatteryPowerKey
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return info }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let minutes = Int(parts[1]) else { continue }
            if parts[0] == "displaysleep" { info.displayMinutes = minutes }
            if parts[0] == "sleep" { info.sleepMinutes = minutes }
        }
        return info
    }

    var summary: String {
        guard let display = displayMinutes, let sleep = sleepMinutes else {
            return "Follows your System Settings."
        }
        let source = onBattery ? "On battery" : "On power"
        let displayText = display == 0 ? "display never turns off" : "display off after \(display) min"
        let sleepText: String
        if sleep == 0 {
            sleepText = "Mac never sleeps on its own"
        } else if sleep <= display {
            sleepText = "Mac sleeps right after"
        } else {
            sleepText = "Mac sleeps after \(sleep) min"
        }
        return "\(source): \(displayText), \(sleepText)."
    }
}

// MARK: - Power assertions (IOKit). Held in-process, released on quit or crash.

final class PowerManager {
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0

    var isActive: Bool { systemAssertion != 0 }

    func start(keepScreenOn: Bool) {
        stop()
        systemAssertion = create("PreventUserIdleSystemSleep")
        if keepScreenOn {
            displayAssertion = create("PreventUserIdleDisplaySleep")
        }
    }

    func stop() {
        release(&systemAssertion)
        release(&displayAssertion)
    }

    private func create(_ type: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(type as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Stay Awake" as CFString,
                                             &id)
        return ok == kIOReturnSuccess ? id : 0
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}

// MARK: - Lid behaviour (pmset disablesleep). System-wide, persistent, needs admin.

enum LidControl {
    /// Reads IOPMrootDomain's SleepDisabled. No privileges required.
    static func staysAwakeOnLidClose() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    /// Shows the standard macOS admin password dialog.
    static func setStaysAwakeOnLidClose(_ enabled: Bool) {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func timerFinished() {
        let content = UNMutableNotificationContent()
        content.title = "Stay Awake finished"
        content.body = "The timer ran out. Your Mac can sleep normally again."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - State

final class AppState: ObservableObject {
    @Published var isOn = false
    @Published var remaining: TimeInterval?
    @Published var duration: AwakeDuration = .hr1
    @Published var keepScreenOn = true
    @Published var lidStaysAwake = false
    @Published var loginItemOn = false
    @Published var systemInfo = SystemSleepInfo()

    var onChange: (() -> Void)?
    var onExpire: (() -> Void)?

    private let power = PowerManager()
    private let defaults = UserDefaults.standard
    private var expiry: Date?
    private var timer: Timer?
    private var publishedBucket: Int?

    init() {
        keepScreenOn = defaults.object(forKey: "keepScreenOn") as? Bool ?? true
        if let saved = defaults.object(forKey: "duration") as? Int,
           let d = AwakeDuration(rawValue: saved) {
            duration = d
        }
        refreshExternalState()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Actions

    func turnOn() {
        power.start(keepScreenOn: keepScreenOn)
        expiry = duration.seconds.map { Date().addingTimeInterval($0) }
        if expiry != nil { Notifier.requestPermission() }
        isOn = power.isActive
        publishedBucket = nil
        updateRemaining()
        onChange?()
    }

    func turnOff() {
        power.stop()
        expiry = nil
        isOn = false
        remaining = nil
        publishedBucket = nil
        onChange?()
    }

    func select(_ d: AwakeDuration) {
        duration = d
        defaults.set(d.rawValue, forKey: "duration")
        turnOn()   // starts, or restarts the clock with the new length
    }

    func setKeepScreenOn(_ value: Bool) {
        keepScreenOn = value
        defaults.set(value, forKey: "keepScreenOn")
        if isOn { power.start(keepScreenOn: value) }
    }

    func setLidStaysAwake(_ value: Bool) {
        guard value != LidControl.staysAwakeOnLidClose() else { return }
        LidControl.setStaysAwakeOnLidClose(value)
        lidStaysAwake = LidControl.staysAwakeOnLidClose()   // trust the system, not the request
    }

    func setLoginItem(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item error: \(error)")
        }
        loginItemOn = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads values that live outside this app and can change behind its back.
    func refreshExternalState(sync: Bool = false) {
        lidStaysAwake = LidControl.staysAwakeOnLidClose()
        loginItemOn = SMAppService.mainApp.status == .enabled
        if sync {
            systemInfo = SystemSleepInfo.read()
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let info = SystemSleepInfo.read()
                DispatchQueue.main.async { self.systemInfo = info }
            }
        }
    }

    // MARK: Ticking

    private func tick() {
        guard isOn else { return }
        if let end = expiry, Date() >= end {
            turnOff()
            onExpire?()
            return
        }
        updateRemaining()
    }

    /// Publishes only when the displayed value changes (each minute, or each second under a minute),
    /// so the UI does not re-render every tick.
    private func updateRemaining() {
        let value = expiry.map { max(0, $0.timeIntervalSinceNow) }
        let bucket: Int? = value.map { let t = Int($0.rounded(.up)); return t >= 60 ? (t / 60) * 60 : t }
        if bucket != publishedBucket || (value == nil) != (remaining == nil) {
            publishedBucket = bucket
            remaining = value
        }
    }

    /// "1 h 12 min", "47 min", "42 s"
    var remainingText: String? {
        guard let left = remaining else { return nil }
        let total = Int(left.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(s) s"
    }

    /// "1h 12m", "47m", "42s" for the menu bar
    var compactRemaining: String? {
        guard let left = remaining else { return nil }
        let total = Int(left.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }
}

// MARK: - Panel content (SwiftUI). The glass container is AppKit, see AppDelegate.buildPanel.

/// A switch that renders identically whether or not the popover window is key,
/// so the app never has to steal focus to look right.
struct PillToggleStyle: ToggleStyle {
    var label: String
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        let w: CGFloat = small ? 32 : 40
        let h: CGFloat = small ? 19 : 23
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.22))
                Circle()
                    .fill(Color.white)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .frame(width: w, height: h)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        .accessibilityLabel(label)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            caption("Keep awake for")
            card {
                systemDefaultRow
                separator
                chipGrid.padding(10)
            }
            card {
                toggleRow(title: "Keep the screen on",
                          subtitle: state.keepScreenOn ? "Display stays lit while awake."
                                                       : "Display may turn off. Mac stays awake.",
                          isOn: Binding(get: { state.keepScreenOn }, set: { state.setKeepScreenOn($0) }))
                separator
                toggleRow(title: "Stay awake with lid closed",
                          subtitle: state.lidStaysAwake
                              ? "System-wide and persistent. Watch for heat."
                              : "System-wide setting. Asks for your password.",
                          subtitleColor: state.lidStaysAwake ? .orange : .secondary,
                          isOn: Binding(get: { state.lidStaysAwake }, set: { state.setLidStaysAwake($0) }))
            }
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: state.isOn ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(state.isOn ? Color.accentColor : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.isOn ? "Staying awake" : "Sleeping normally")
                    .font(.system(size: 14, weight: .semibold))
                Text(state.isOn ? (state.remainingText.map { "\($0) left" } ?? "No time limit")
                                : "Your Mac sleeps when idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Toggle("Stay awake", isOn: Binding(
                get: { state.isOn },
                set: { $0 ? state.turnOn() : state.turnOff() }))
                .toggleStyle(PillToggleStyle(label: "Stay awake"))
                .labelsHidden()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.leading, 4)
            .padding(.bottom, -5)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, 12)
    }

    private var systemDefaultRow: some View {
        Button {
            state.turnOff()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: state.isOn ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(state.isOn ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System default")
                        .font(.system(size: 13, weight: .medium))
                    Text(state.systemInfo.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("System default")
    }

    private var chipGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(AwakeDuration.allCases) { d in
                let selected = state.isOn && state.duration == d
                Button {
                    state.select(d)
                } label: {
                    Text(d.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(d.label)
            }
        }
    }

    private func toggleRow(title: String, subtitle: String, subtitleColor: Color = .secondary,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(PillToggleStyle(label: title, small: true))
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { state.loginItemOn }, set: { state.setLoginItem($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer()
            Button("Quit", action: quit)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = AppState()
    private var popover: NSPopover!
    private var hostingController: NSHostingController<PanelView>!
    private var keyMonitor: Any?
    private var iconTimer: Timer?
    private var iconShowsOn: Bool?
    private var iconUpdates = 0
    private var lastClose = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            // Fixed-width digits so the countdown never changes width and never shifts the menu bar.
            let size = NSFont.menuBarFont(ofSize: 0).pointSize
            button.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            button.setAccessibilityIdentifier("stayawake.statusitem")
        }
        buildPopover()
        refreshIcon()

        state.onChange = { [weak self] in self?.refreshIcon() }
        state.onExpire = { [weak self] in
            self?.refreshIcon()
            Notifier.timerFinished()
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }

        // Only when launched with STAYAWAKE_DEBUG=1: lets scripts drive the UI for screenshots and tests.
        if ProcessInfo.processInfo.environment["STAYAWAKE_DEBUG"] == "1" {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.anupam0309.stayawake.debug"), object: nil, queue: .main
            ) { [weak self] note in
                self?.handleDebugCommand(note.object as? String ?? "")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.turnOff()
    }

    // MARK: Menu bar icon

    /// Cheap and idempotent: only touches the button when something actually changed.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let on = state.isOn
        if iconShowsOn != on {
            button.image = NSImage(systemSymbolName: on ? "moon.zzz.fill" : "moon.zzz",
                                   accessibilityDescription: on ? "Stay Awake on" : "Stay Awake off")
            button.image?.isTemplate = true
            iconShowsOn = on
            iconUpdates += 1
        }
        let title = on ? (state.compactRemaining.map { " \($0)" } ?? "") : ""
        if button.title != title {
            button.title = title
            iconUpdates += 1
        }
        let tip = on ? "Stay Awake: on" + (state.remainingText.map { ", \($0) left" } ?? ", no time limit")
                     : "Stay Awake: off"
        if button.toolTip != tip { button.toolTip = tip }
    }

    // MARK: Popover

    private func buildPopover() {
        hostingController = NSHostingController(rootView: PanelView(state: state, quit: { NSApp.terminate(nil) }))
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient      // closes on any click outside
        popover.animates = true            // the standard drop-out from the icon
        popover.delegate = self
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown { hidePanel(); return }
        // Clicking the icon while open: the transient popover already closed on mouse-down. Do not reopen.
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        state.refreshExternalState(sync: true)
        // Never activate the app: the user's current app keeps keyboard focus the whole time.
        NSApp.unhideWithoutActivation()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        // Local monitor: only sees key presses delivered to this app's own windows.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hidePanel(); return nil }   // Esc
            return event
        }
    }

    private func hidePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        lastClose = Date()
        statusItem.button?.highlight(false)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        // Never stay the active app with no windows: that would swallow the user's Cmd shortcuts.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Stay Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Debug hook (STAYAWAKE_DEBUG=1 only)

    private var popoverWindow: NSWindow? { hostingController.view.window }

    private func handleDebugCommand(_ cmd: String) {
        let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "open": showPanel()
        case "close": hidePanel()
        case "pin": popover.behavior = (parts.count > 1 && parts[1] == "1") ? .applicationDefined : .transient
        case "off": state.turnOff()
        case "on": if parts.count > 1, let raw = Int(parts[1]), let d = AwakeDuration(rawValue: raw) { state.select(d) }
        case "screen": state.setKeepScreenOn(parts.count > 1 && parts[1] == "1")
        case "login":
            state.setLoginItem(parts.count > 1 && parts[1] == "1")
            log("login item enabled=\(state.loginItemOn) bundle=\(Bundle.main.bundlePath)")
        case "snap":
            if parts.count > 1, let w = popoverWindow { snapshot(window: CGWindowID(w.windowNumber), to: parts[1]) }
        case "snapbutton":   // renders the status item button itself (icon + countdown)
            guard parts.count > 1, let button = statusItem.button,
                  let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
            button.cacheDisplay(in: button.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: parts[1]))
                log("snapshot \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(parts[1])")
            }
        case "frames": break
        default: return
        }
        guard let button = statusItem.button, let w = button.window else { return }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let b = w.convertToScreen(button.convert(button.bounds, to: nil))
        let p = popoverWindow?.frame ?? .zero
        log(String(format: "frames button=%.0f,%.0f,%.0f,%.0f popover=%.0f,%.0f,%.0f,%.0f shown=%d active=%d iconUpdates=%d",
                   b.minX, screenH - b.maxY, b.width, b.height,
                   p.minX, screenH - p.maxY, p.width, p.height, popover.isShown ? 1 : 0,
                   NSApp.isActive ? 1 : 0, iconUpdates))
    }

    private func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    // CGWindowListCreateImage is hidden from Swift in the macOS 26 SDK but still exported by CoreGraphics.
    // Capturing this app's own windows needs no screen-recording permission.
    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private func legacyWindowImage(_ rect: CGRect, _ option: CGWindowListOption, _ id: CGWindowID,
                                   _ imageOption: CGWindowImageOption) -> CGImage? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: WindowImageFn.self)
        return fn(rect, option.rawValue, id, imageOption.rawValue)?.takeRetainedValue()
    }

    private func snapshot(window id: CGWindowID, to path: String) {
        guard let img = legacyWindowImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            log("snapshot failed for window \(id)"); return
        }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        log("snapshot \(img.width)x\(img.height) -> \(path)")
    }
}

// MARK: - Entry point

@main
enum StayAwakeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
