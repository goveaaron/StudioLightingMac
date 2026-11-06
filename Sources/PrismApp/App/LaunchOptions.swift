import Foundation

/// Command-line / environment launch options.
///
///   --demo                 start with the built-in London Studio demo rig
///   --screenshot-tour DIR  render every registered UI scene to DIR/*.png and quit (CI)
///   --self-test            run the built-in self test, print results, exit with status (CI)
///   --safe-mode            don't restore last session or open hardware (also offered after a crash)
///   --no-hardware          never open DMX devices (simulation only)
///   --project PATH         open a project file on launch
///   --reset                forget app preferences (keeps projects)
struct LaunchOptions {
    var demo = false
    var screenshotTourDirectory: URL?
    var selfTest = false
    var safeMode = false
    var noHardware = false
    var projectPath: URL?
    var reset = false

    static let current = LaunchOptions(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)

    init(arguments: [String], environment: [String: String] = [:]) {
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            func next() -> String? {
                guard i + 1 < arguments.count else { return nil }
                i += 1
                return arguments[i]
            }
            switch a {
            case "--demo": demo = true
            case "--screenshot-tour":
                if let p = next() { screenshotTourDirectory = URL(fileURLWithPath: p, isDirectory: true) }
            case "--self-test": selfTest = true
            case "--safe-mode": safeMode = true
            case "--no-hardware": noHardware = true
            case "--project":
                if let p = next() { projectPath = URL(fileURLWithPath: p) }
            case "--reset": reset = true
            default: break // ignore unknown (e.g. -NSDocumentRevisionsDebugMode from Xcode)
            }
            i += 1
        }
        if let dir = environment["PRISM_SCREENSHOT_TOUR"], !dir.isEmpty {
            screenshotTourDirectory = URL(fileURLWithPath: dir, isDirectory: true)
        }
        if environment["PRISM_NO_HARDWARE"] == "1" { noHardware = true }
        // Automated runs never touch real hardware and always use the demo rig.
        if screenshotTourDirectory != nil || selfTest {
            noHardware = true
            demo = true
        }
    }

    var isAutomated: Bool { screenshotTourDirectory != nil || selfTest }
}
