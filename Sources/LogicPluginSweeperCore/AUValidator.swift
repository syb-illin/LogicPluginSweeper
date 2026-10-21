import Foundation

public struct AUValidationResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool

    public var passed: Bool { exitCode == 0 && !timedOut }
}

public final class AUValidator: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/auval"), arguments: [String] = ["-a"]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public static func validate(plugin: PluginRecord, timeout: TimeInterval = 30) async -> AUValidationResult? {
        guard plugin.format == .audioUnit, let bundleURL = plugin.bundleURL,
              let components = Bundle(url: bundleURL)?.infoDictionary?["AudioComponents"] as? [[String: Any]],
              let component = components.first,
              let type = component["type"] as? String,
              let subtype = component["subtype"] as? String,
              let manufacturer = component["manufacturer"] as? String else { return nil }
        return await AUValidator(arguments: ["-v", type, subtype, manufacturer]).validateAll(timeout: timeout)
    }

    public func validateAll(timeout: TimeInterval = 30) async -> AUValidationResult {
        let controller = ProcessController()
        let processTask = Task.detached(priority: .utility) {
            self.runProcess(arguments: self.arguments, timeout: timeout, controller: controller)
        }
        return await withTaskGroup(of: AUValidationResult.self) { group in
            group.addTask { await processTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                controller.terminate()
                return AUValidationResult(exitCode: -1, output: "Timeout", timedOut: true)
            }
            let first = await group.next() ?? AUValidationResult(exitCode: -1, output: "Validation indisponible", timedOut: true)
            group.cancelAll()
            controller.terminate()
            return first
        }
    }

    private func runProcess(arguments: [String], timeout: TimeInterval, controller: ProcessController) -> AUValidationResult {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("LogicPluginSweeper-auval-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            return AUValidationResult(exitCode: -1, output: "Validation indisponible", timedOut: false)
        }
        guard let output = try? FileHandle(forWritingTo: outputURL) else {
            return AUValidationResult(exitCode: -1, output: "Validation indisponible", timedOut: false)
        }
        defer { try? output.close() }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            controller.attach(process)
        } catch {
            return AUValidationResult(exitCode: -1, output: error.localizedDescription, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return AUValidationResult(exitCode: -1, output: "Validation interrompue après délai", timedOut: true)
        }
        try? output.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return AUValidationResult(exitCode: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "", timedOut: false)
    }

    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var terminationRequested = false

        func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldTerminate = terminationRequested
            lock.unlock()
            if shouldTerminate { process.terminate() }
        }

        func terminate() {
            lock.lock()
            terminationRequested = true
            let process = self.process
            lock.unlock()
            if process?.isRunning == true { process?.terminate() }
        }
    }
}
