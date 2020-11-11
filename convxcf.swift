import Foundation

enum Command: String {
    case lipo = "/usr/bin/lipo"
    case readlink = "/usr/bin/readlink"
    case mkdir = "/bin/mkdir"
    case cp = "/bin/cp"
    case rm = "/bin/rm"
    case xcodebuild = "/usr/bin/xcodebuild"
    case ls = "/bin/ls"
}

struct Program {

    private static let archToPlatform = [
        "i386": "x86",
        "x86_64": "x86",
        "armv7": "arm",
        "armv7s": "arm",
        "arm64": "arm",
        "arm64e": "arm"
    ]

    static func run() {
        guard CommandLine.arguments.count > 1 else { return }
        let frameworkPath = CommandLine.arguments[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard frameworkPath.hasSuffix(".framework") else { return }

        guard
            let frameworkName = frameworkPath.components(separatedBy: "/").last?
                .components(separatedBy: ".").first,
            let binaryInfo = Process.stringFromExecuting(.lipo, [
                "-detailed_info",
                frameworkPath.appendingPathComponent(frameworkName)
            ])
        else { return }

        let archs = binaryInfo.matches("architecture (\\w+)")
        let platforms = Set(archs.compactMap { archToPlatform[$0] })
        guard !platforms.isEmpty else { return }

        guard let resolvedPath = Process.stringFromExecuting(.readlink, [
            frameworkPath.appendingPathComponent(frameworkName)
        ]) else { return }

        let partialBinaryPath = !resolvedPath.isEmpty ? resolvedPath : frameworkName
        let binaryPath = frameworkPath.appendingPathComponent(partialBinaryPath)
        var buildArgs = ["-create-xcframework"]

        if platforms.count == 1 {
            buildArgs.append(contentsOf: ["-framework", frameworkPath])
        } else {
            for platform in platforms {
                Process.execute(.mkdir, [platform])

                let platformFrameworkPath = platform.appendingPathComponent("\(frameworkName).framework")
                Process.execute(.cp, ["-a", frameworkPath, platformFrameworkPath])

                let platformBinaryPath = platformFrameworkPath.appendingPathComponent(partialBinaryPath)
                let currentArchs = archs.filter { archToPlatform[$0] == platform }

                if currentArchs.count == 1 {
                    Process.execute(.lipo, [binaryPath, "-thin", currentArchs[0], "-output", platformBinaryPath])
                } else {
                    for arch in currentArchs {
                        Process.execute(.lipo, [binaryPath, "-thin", arch, "-output", arch])
                    }
                    Process.execute(.lipo, ["-create"] + currentArchs + ["-output", platformBinaryPath])
                    Process.execute(.rm, currentArchs)
                }

                buildArgs.append(contentsOf: ["-framework", platformFrameworkPath])
            }
        }

        buildArgs.append(contentsOf: ["-output", "\(frameworkName).xcframework"])
        Process.execute(.rm, ["-rf", "\(frameworkName).xcframework"])
        Process.execute(.xcodebuild, buildArgs)
        Process.execute(.rm, ["-rf"] + platforms)
    }
}

extension String {

    func matches(_ regex: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: regex)
            let results = regex.matches(in: self, range: NSRange(startIndex..., in: self))
            return results.compactMap {
                Range($0.range(at: 1), in: self)
                    .flatMap { String(self[$0]) }
            }
        } catch {
            return []
        }
    }

    func appendingPathComponent(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}

extension Process {

    static func dataFromExecuting(_ command: Command, _ arguments: [String]) -> Data? {
        let task = Process()
        task.launchPath = command.rawValue
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return data
        } catch {
            return nil
        }
    }

    static func stringFromExecuting(_ command: Command, _ arguments: [String]) -> String? {
        return dataFromExecuting(command, arguments)
            .flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func execute(_ command: Command, _ arguments: [String]) {
        _ = dataFromExecuting(command, arguments)
    }
}

Program.run()
