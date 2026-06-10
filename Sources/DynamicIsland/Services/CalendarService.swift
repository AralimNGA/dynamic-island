import Foundation
import AppKit
import Combine

/// Reads the next event from the Calendar app via AppleScript (Automation), which
/// works with an ad-hoc signature — unlike EventKit, which macOS 26 blocks for
/// ad-hoc-signed apps.
final class CalendarService: ObservableObject {
    struct Event: Equatable {
        let title: String
        let when: String
        let location: String
    }

    @Published var nextEvent: Event?
    @Published var loading = false
    @Published var loaded = false
    @Published var calendarRunning = false
    @Published var permissionDenied = false

    private let queue = DispatchQueue(label: "island.cal")

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.iCal" }
        calendarRunning = running
        guard running else { loaded = true; return }
        loading = true
        queue.async { [weak self] in
            let result = self?.query()
            DispatchQueue.main.async {
                self?.loading = false
                self?.loaded = true
                if let result { self?.nextEvent = result }
            }
        }
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.refresh() }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func query() -> Event? {
        let src = """
        if application "Calendar" is running then
          tell application "Calendar"
            set nowD to (current date)
            set endD to nowD + (4 * days)
            set bestStart to endD
            set bestTitle to ""
            set bestLoc to ""
            set foundOne to false
            repeat with c in calendars
              try
                set evs to (every event of c whose start date ≥ nowD and start date ≤ endD)
                repeat with e in evs
                  set sd to start date of e
                  if sd < bestStart then
                    set bestStart to sd
                    set bestTitle to summary of e
                    try
                      set bestLoc to location of e
                    on error
                      set bestLoc to ""
                    end try
                    set foundOne to true
                  end if
                end repeat
              end try
            end repeat
            if not foundOne then return "NONE"
            set wd to (weekday of bestStart) as string
            set tm to time string of bestStart
            return bestTitle & linefeed & (wd & ", " & tm) & linefeed & bestLoc
          end tell
        end if
        """
        guard let out = run(src) else { return nil }
        if out == "NONE" || out.isEmpty { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return Event(title: parts[0], when: parts[1], location: parts.count > 2 ? parts[2] : "")
    }

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            let num = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if num == -1743 {
                DispatchQueue.main.async { self.permissionDenied = true }
            }
            return nil
        }
        DispatchQueue.main.async { if self.permissionDenied { self.permissionDenied = false } }
        return result.stringValue
    }
}
