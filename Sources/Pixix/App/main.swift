import AppKit

let launchStart = DispatchTime.now()

// Answer --version before any of AppKit starts.
if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    print("Pixix \(version)")
    exit(0)
}

/// Prints a timestamped checkpoint when PIXIX_TRACE is set. For finding out where launch time goes.
@MainActor
func trace(_ label: @autoclosure () -> String) {
    guard isTracing else { return }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - launchStart.uptimeNanoseconds) / 1_000_000
    FileHandle.standardError.write(Data(String(format: "%6.1f ms  %@\n", elapsed, label()).utf8))
}

let isTracing = ProcessInfo.processInfo.environment["PIXIX_TRACE"] != nil

let application = NSApplication.shared
trace("application created")
let appDelegate = AppDelegate()
application.delegate = appDelegate
// Maintenance runs have no window and should not flash an icon in the Dock; neither should a snapshot run,
// which works out of sight.
let isMaintenanceRun = CommandLine.arguments.contains { ["--make-default", "--restore-default", "--snapshot"].contains($0) }
application.setActivationPolicy(isMaintenanceRun ? .accessory : .regular)
application.run()
