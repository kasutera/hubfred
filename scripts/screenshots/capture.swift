import AppKit
import Vision

let arguments = Array(CommandLine.arguments.dropFirst())
let alfredBundleIdentifier = "com.runningwithcrayons.Alfred"
let alfred = "tell application id \"\(alfredBundleIdentifier)\" to "

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func dismiss() {
    guard let alfredApplication = NSRunningApplication.runningApplications(
        withBundleIdentifier: alfredBundleIdentifier
    ).first else { return }
    let alfredPID = Int(alfredApplication.processIdentifier)
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let hasCaptureWindow = windows.contains { window in
        guard window["kCGWindowOwnerName"] as? String == "Alfred",
              window["kCGWindowOwnerPID"] as? Int == alfredPID,
              let bounds = window["kCGWindowBounds"] as? [String: Any],
              let width = bounds["Width"] as? Double else { return false }
        return width >= 350
    }
    guard hasCaptureWindow else { return }
    guard let status = try? run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to activate"]),
          status == 0 else {
        fail("Could not dismiss Alfred after capture.")
    }
}

if arguments == ["--dismiss"] {
    dismiss()
    exit(0)
}
guard arguments.count == 1 else {
    fail("Usage: capture.swift <output-directory> | --dismiss")
}
let output = URL(fileURLWithPath: arguments[0], isDirectory: true)

func capture(_ name: String, command: String, keyword: String? = nil, markers: [String]) throws {
    if let keyword {
        guard try run("/usr/bin/osascript", ["-e", alfred + "search \"\(keyword)\""]) == 0 else {
            fail("Alfred did not open the \(name) search field.")
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    guard try run("/usr/bin/osascript", ["-e", alfred + command]) == 0 else {
        fail("Alfred did not open the \(name) screenshot view.")
    }
    let expectsDashboard = keyword == nil
    let candidate = output.appendingPathComponent("candidate.png")
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.25)
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window["kCGWindowOwnerName"] as? String == "Alfred" {
            guard let bounds = window["kCGWindowBounds"] as? [String: Any],
                  let width = bounds["Width"] as? Double, width >= 350,
                  (width >= 1000) == expectsDashboard,
                  let id = window["kCGWindowNumber"] as? Int,
                  try run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), candidate.path]) == 0
            else { continue }

            let request = VNRecognizeTextRequest()
            guard (try? VNImageRequestHandler(url: candidate).perform([request])) != nil else { continue }
            let lines = (request.results ?? []).compactMap { observation -> String? in
                if expectsDashboard && observation.boundingBox.minX < 0.47 { return nil }
                return observation.topCandidates(1).first?.string
            }
            let text = lines.joined(separator: " ").lowercased()
            guard markers.allSatisfy({ text.contains($0) }) else { continue }
            // Alfred appends default results after script results if there is room.
            if let keyword {
                let lastTitle = keyword == "pr" ? "simplify saved search settings" : "show useful empty states"
                guard let height = bounds["Height"] as? Double,
                      let lastRow = (request.results ?? []).first(where: {
                          $0.topCandidates(1).first?.string.lowercased().contains(lastTitle) == true
                      }),
                      lastRow.boundingBox.midY * height < 65
                else { continue }
            }
            if keyword == "pr" {
                guard (request.results ?? []).contains(where: {
                    $0.boundingBox.midY > 0.7 && $0.topCandidates(3).contains {
                        $0.string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pr"
                    }
                }) else { continue }
            }

            let image = NSBitmapImageRep(data: try Data(contentsOf: candidate))
            guard let image, image.hasAlpha,
                  image.colorAt(x: 0, y: 0)!.alphaComponent < 0.99
            else { fail("The \(name) capture has no transparent corner.") }
            let samples: [(Double, Double)] = [(0.2, 0.4), (0.7, 0.4), (0.2, 0.8), (0.7, 0.8)]
            let alpha = samples.map { x, y in
                image.colorAt(x: Int(Double(image.pixelsWide) * x),
                              y: Int(Double(image.pixelsHigh) * y))!.alphaComponent
            }
            guard alpha.allSatisfy({ $0 >= 0.99 }) else {
                fail("The \(name) background is translucent (\(alpha)). Set Alfred to Alfred Classic and retry.")
            }

            try FileManager.default.moveItem(at: candidate, to: output.appendingPathComponent("\(name).png"))
            return
        }
    }
    fail("The \(name) window did not display its expected demo data. No screenshots were replaced.")
}

guard CGPreflightScreenCaptureAccess() else {
    fail("Allow Screen Recording for the terminal in System Settings and retry.")
}
try capture("picker", command: "search \"pr \"", keyword: "pr",
            markers: ["add keyboard navigation", "improve search relevance", "draft"])
try capture("issue-picker", command: "search \"is demo-hub\"", keyword: "is",
            markers: ["improve keyboard navigation", "restore archived projects", "assigned"])
try capture("pr-dashboard", command: "run trigger \"pr-dashboard\" in workflow \"org.hubfred.screenshots\"",
            markers: ["command palette shortcuts", "keyboard behavior", "return to the search field"])
try capture("dashboard", command: "run trigger \"issue-dashboard\" in workflow \"org.hubfred.screenshots\"",
            markers: ["saved views", "acceptance criteria", "preserve selection on refresh"])
