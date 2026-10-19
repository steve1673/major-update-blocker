import AppKit
import Foundation

// MARK: - Constants

let appID = "org.majorupdateblocker"
let profileID = "org.majorupdateblocker.profile"
let accessDomain = "com.apple.applicationaccess" as CFString
let majorKey = "forceDelayedMajorSoftwareUpdates" as CFString
let deferralDays = 90
let renewAfterDays = 75
let supportDir = "/Library/Application Support/MajorUpdateBlocker"
let statePath = ProcessInfo.processInfo.environment["MUB_STATE"] ?? (supportDir + "/state.plist")
let logPath = ProcessInfo.processInfo.environment["MUB_LOG"] ?? "/Library/Logs/MajorUpdateBlocker.log"
let managedPlist = "/Library/Managed Preferences/com.apple.applicationaccess.plist"
let settingsDomain = "com.apple.systempreferences"
let badgeKey = "AttentionPrefBundleIDs"
let scanInterval: TimeInterval = 6 * 3600
let promptInterval: TimeInterval = 24 * 3600

// MARK: - Shared state (machine-wide, tiny, non-sensitive)

final class State {
    var d: [String: Any]
    init(_ d: [String: Any]) { self.d = d }

    static func load() -> State {
        State(NSDictionary(contentsOfFile: statePath) as? [String: Any] ?? [:])
    }

    static func update(_ change: (State) -> Void) {
        let s = load()
        change(s)
        s.save()
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: supportDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777])
        (d as NSDictionary).write(toFile: statePath, atomically: true)
        chmod(statePath, 0o666)
    }

    var enabled: Bool { get { d["enabled"] as? Bool ?? false } set { d["enabled"] = newValue } }
    var lastPrompt: Date? { get { d["lastPrompt"] as? Date } set { d["lastPrompt"] = newValue } }
    var lastScan: Date? { get { d["lastScan"] as? Date } set { d["lastScan"] = newValue } }
    var minorPending: Bool? { get { d["minorPending"] as? Bool } set { d["minorPending"] = newValue } }
    var badgeSuppressed: Bool { get { d["badgeSuppressed"] as? Bool ?? false } set { d["badgeSuppressed"] = newValue } }
}

// MARK: - Helpers

/// Runs a tool and returns (exit status, stdout+stderr), or nil if it timed out or failed to launch.
func run(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> (Int32, String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return nil }
    // Drain the pipe while the process runs, or large output (e.g. ps) fills it and deadlocks.
    var data = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        return nil
    }
    drained.wait()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func profileActive() -> Bool {
    CFPreferencesAppSynchronize(accessDomain)
    return CFPreferencesAppValueIsForced(majorKey, accessDomain)
        && (CFPreferencesCopyAppValue(majorKey, accessDomain) as? Bool) == true
}

/// Age of the installed restriction, taken from the managed-preferences file, which macOS rewrites on (re)install.
func profileAgeDays() -> Int? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: managedPlist),
          let date = attrs[.modificationDate] as? Date else { return nil }
    return max(0, Int(Date().timeIntervalSince(date) / 86400))
}

func renewalDue() -> Bool { (profileAgeDays() ?? 0) >= renewAfterDays }

func needsAttention(_ st: State) -> Bool {
    guard st.enabled else { return false }
    guard !profileActive() || renewalDue() else { return false }
    if let p = st.lastPrompt, Date().timeIntervalSince(p) < promptInterval { return false }
    return true
}

// MARK: - Profile install / removal

func profileXML() -> Data {
    let restrictions: [String: Any] = [
        "PayloadType": "com.apple.applicationaccess",
        "PayloadVersion": 1,
        "PayloadIdentifier": profileID + ".restrictions",
        "PayloadUUID": "6F1D2A64-3B7E-4C55-9C1A-0B5E8D2F7A11",
        "PayloadDisplayName": "Defer major macOS updates",
        "forceDelayedMajorSoftwareUpdates": true,
        "enforcedSoftwareUpdateMajorOSDeferredInstallDelay": deferralDays,
    ]
    let profile: [String: Any] = [
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": profileID,
        "PayloadUUID": "A3C94E70-58D2-4B8F-8E36-1D7F2B90C4E5",
        "PayloadDisplayName": "Major Update Blocker",
        "PayloadDescription": "Hides major macOS upgrades. Minor updates are unaffected. Managed by Major Update Blocker.",
        "PayloadOrganization": "Major Update Blocker",
        "PayloadScope": "System",
        "PayloadRemovalDisallowed": false,
        "PayloadContent": [restrictions],
    ]
    return (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
}

func openProfilesPane() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.configurationprofiles") {
        NSWorkspace.shared.open(url)
    }
}

func installProfile() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Major Update Blocker.mobileconfig")
    do { try profileXML().write(to: url) } catch { return }
    NSWorkspace.shared.open(url)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { openProfilesPane() }
}

/// Returns true if removed. Needs admin rights; macOS asks for them.
func removeProfile() -> Bool {
    let script = "do shell script \"/usr/bin/profiles remove -identifier \(profileID)\" with administrator privileges"
    guard let (status, _) = run("/usr/bin/osascript", ["-e", script], timeout: 120) else { return false }
    return status == 0
}

// MARK: - Badge handling (red circle on System Settings)

func scanMinorPending() -> Bool? {
    guard let (_, out) = run("/usr/sbin/softwareupdate", ["-l"], timeout: 240) else { return nil }
    let current = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var minor = false
    for line in out.split(separator: "\n") {
        guard let titleRange = line.range(of: "Title: ") else { continue }
        let rest = line[titleRange.upperBound...]
        let title = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        if title.hasPrefix("Command Line Tools") { continue }
        var version = ""
        if let v = rest.range(of: "Version: ") {
            version = String(rest[v.upperBound...].prefix { $0 != "," && $0 != " " })
        }
        let major = Int(version.split(separator: ".").first ?? "") ?? current
        if title.hasPrefix("macOS") && major > current { continue }   // major upgrade: ignore
        minor = true
    }
    return minor
}

func badgeValue() -> String? {
    guard let (status, out) = run("/usr/bin/defaults", ["read", settingsDomain, badgeKey], timeout: 10), status == 0 else { return nil }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

func restartDock() { _ = run("/usr/bin/killall", ["Dock"], timeout: 10) }

func suppressBadge() {
    guard let v = badgeValue(), v != "0" else { return }
    _ = run("/usr/bin/defaults", ["write", settingsDomain, badgeKey, "0"], timeout: 10)
    restartDock()
    State.update { $0.badgeSuppressed = true }
}

func restoreBadge() {
    guard State.load().badgeSuppressed else { return }
    _ = run("/usr/bin/defaults", ["delete", settingsDomain, badgeKey], timeout: 10)
    restartDock()
    State.update { $0.badgeSuppressed = false }
}

/// Hides the badge unless a minor update is pending. Does nothing when blocking is off.
func maintainBadge() {
    let st = State.load()
    guard st.enabled else { restoreBadge(); return }
    var minor = st.minorPending
    if minor == nil || st.lastScan == nil || Date().timeIntervalSince(st.lastScan!) > scanInterval {
        if let r = scanMinorPending() {
            minor = r
            State.update { $0.minorPending = r; $0.lastScan = Date() }
        }
    }
    switch minor {
    case .some(false): suppressBadge()
    case .some(true): restoreBadge()
    case .none: break
    }
}

// MARK: - Installer blocking (root LaunchDaemon, `--daemon`)
//
// Apple's 90-day deferral expires per release, so this layer stops a newer major
// macOS installer from running at all. It only touches processes that live inside an
// "Install macOS*.app" whose version has a higher major number than this Mac's.

let installerNames: [String: Int] = [   // fallback when Info.plist has no usable version
    "Big Sur": 11, "Monterey": 12, "Ventura": 13, "Sonoma": 14, "Sequoia": 15, "Tahoe": 26,
]

/// Returns the .app path if the command line starts inside an "Install macOS*.app".
func installerApp(in command: String) -> String? {
    guard command.hasPrefix("/"), let r = command.range(of: ".app/") else { return nil }
    let app = String(command[..<r.upperBound].dropLast())          // ".../Install macOS X.app"
    let name = (app as NSString).lastPathComponent
    return name.hasPrefix("Install macOS") ? app : nil
}

func installerMajor(_ appPath: String) -> Int? {
    let plist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist")
    if let v = plist?["CFBundleShortVersionString"] as? String,
       let major = Int(v.split(separator: ".").first ?? ""), major >= 11 { return major }
    let name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
    for (codename, major) in installerNames where name.contains(codename) { return major }
    return nil
}

func logLine(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: false, encoding: .utf8)
    }
}

func runDaemon() -> Never {
    let current = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var cache: [String: Int?] = [:]
    var logged = Set<String>()
    logLine("daemon started (macOS \(current))")
    while true {
        if State.load().enabled,
           let (_, out) = run("/bin/ps", ["-axww", "-o", "pid=,command="], timeout: 10) {
            for raw in out.split(separator: "\n") {
                let line = raw.drop { $0 == " " }
                guard let sp = line.firstIndex(of: " "), let pid = Int32(line[..<sp]) else { continue }
                let command = String(line[line.index(after: sp)...])
                guard let app = installerApp(in: command) else { continue }
                if cache[app] == nil { cache[app] = installerMajor(app) }
                guard let major = cache[app] ?? nil, major > current else { continue }
                if kill(pid, SIGKILL) == 0 && logged.insert("\(pid)").inserted {
                    logLine("blocked macOS \(major) installer (pid \(pid)): \(app)")
                }
            }
        }
        sleep(3)
    }
}

// MARK: - UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let background: Bool
    let toggle = NSSwitch()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let actionButton = NSButton(title: "", target: nil, action: nil)
    var window: NSWindow!
    var timer: Timer?
    var closeScheduled = false

    init(background: Bool) { self.background = background }

    func applicationDidFinishLaunching(_ n: Notification) {
        if background { NSApp.setActivationPolicy(.regular) }
        buildMenu()
        buildWindow()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        State.update { $0.lastPrompt = Date() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        DispatchQueue.global().async { maintainBadge() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let sub = NSMenu()
        sub.addItem(withTitle: "Quit Major Update Blocker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub
        NSApp.mainMenu = main
    }

    func buildWindow() {
        let title = NSTextField(labelWithString: "Block major macOS updates")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        let row = NSStackView(views: [title, toggle])
        row.orientation = .horizontal
        row.distribution = .equalSpacing

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.preferredMaxLayoutWidth = 340
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.bezelStyle = .rounded

        let foot = NSTextField(wrappingLabelWithString:
            "Minor updates install normally. Newer major macOS installers are also stopped from running, even after Apple's 90-day deferral ends.")
        foot.font = .systemFont(ofSize: 11)
        foot.textColor = .secondaryLabelColor
        foot.preferredMaxLayoutWidth = 340

        let stack = NSStackView(views: [row, statusLabel, actionButton, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        row.widthAnchor.constraint(equalToConstant: 340).isActive = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 240),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Major Update Blocker"
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    enum Action { case none, reopen, renew, remove }
    var action: Action = .none

    func refresh() {
        let st = State.load()
        let active = profileActive()
        let age = profileAgeDays()
        toggle.state = st.enabled ? .on : .off
        var healthy = false
        switch (st.enabled, active) {
        case (true, true):
            let left = age.map { max(0, deferralDays - $0) }
            statusLabel.stringValue = "On. Major macOS updates are hidden." +
                (left.map { " Protection renews in about \($0) days." } ?? "")
            if renewalDue() {
                statusLabel.stringValue = "On, but the 90-day window is ending. Renew now to keep updates hidden."
                setAction(.renew, "Renew now")
            } else { setAction(.none, ""); healthy = true }
        case (true, false):
            statusLabel.stringValue = "Waiting for approval. In System Settings, open Privacy & Security > Profiles, select \"Major Update Blocker\" and click Install."
            setAction(.reopen, "Open profile again")
        case (false, true):
            statusLabel.stringValue = "Off, but the profile is still installed. Remove it to finish turning blocking off."
            setAction(.remove, "Remove profile…")
        case (false, false):
            statusLabel.stringValue = "Off. Major macOS upgrades are not blocked."
            setAction(.none, "")
        }
        if background && healthy && !closeScheduled {
            closeScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }

    func setAction(_ a: Action, _ title: String) {
        action = a
        actionButton.title = title
        actionButton.isHidden = (a == .none)
    }

    @objc func actionTapped() {
        switch action {
        case .reopen, .renew: installProfile()
        case .remove: removeAsync()
        case .none: break
        }
    }

    func removeAsync() {
        DispatchQueue.global().async {
            let ok = removeProfile()
            DispatchQueue.main.async {
                if !ok {
                    let a = NSAlert()
                    a.messageText = "Couldn't remove the profile automatically"
                    a.informativeText = "Remove \"Major Update Blocker\" in System Settings > Privacy & Security > Profiles."
                    a.runModal()
                    openProfilesPane()
                }
                self.refresh()
            }
        }
    }

    @objc func toggled(_ sender: NSSwitch) {
        let turningOn = sender.state == .on
        let a = NSAlert()
        if turningOn {
            a.messageText = "Turn on blocking?"
            a.informativeText = "Major macOS upgrades will be hidden. You'll be asked to approve a configuration profile in System Settings. Minor updates are not affected."
            a.addButton(withTitle: "Turn On")
        } else {
            a.messageText = "Turn off blocking?"
            a.informativeText = "Major macOS upgrades will become visible and installable again. You'll be asked for an administrator password to remove the profile."
            a.addButton(withTitle: "Turn Off")
        }
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else {
            sender.state = turningOn ? .off : .on
            return
        }
        State.update { $0.enabled = turningOn }
        if turningOn {
            installProfile()
            DispatchQueue.global().async { maintainBadge() }
        } else if profileActive() {
            DispatchQueue.global().async {
                _ = removeProfile()
                maintainBadge()
                DispatchQueue.main.async { self.refresh() }
            }
        } else {
            DispatchQueue.global().async { maintainBadge() }
        }
        refresh()
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--daemon") { runDaemon() }
let isBackground = CommandLine.arguments.contains("--background")
if isBackground && !needsAttention(State.load()) {
    maintainBadge()
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(background: isBackground)
app.delegate = delegate
app.setActivationPolicy(isBackground ? .accessory : .regular)
app.run()
