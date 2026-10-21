import Foundation
import Darwin

public struct PrivilegedFileMover: Sendable {
    public init() {}

    public func moveItem(from source: URL, to destination: URL) throws {
        let script = """
        on run argv
            set sourcePath to item 1 of argv
            set destinationPath to item 2 of argv
            set ownerID to item 3 of argv
            set groupID to item 4 of argv
            do shell script "/bin/mv -- " & quoted form of sourcePath & " " & quoted form of destinationPath & " && /usr/sbin/chown -R " & ownerID & ":" & groupID & " " & quoted form of destinationPath with administrator privileges
        end run
        """
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, source.path, destination.path, String(getuid()), String(getgid())]
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PrivilegedFileMoverError.unavailable(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let details = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PrivilegedFileMoverError.denied(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public enum PrivilegedFileMoverError: Error, LocalizedError, Sendable {
        case unavailable(String)
        case denied(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let details): "Administrator authorization is unavailable: \(details)"
            case .denied(let details): details.isEmpty ? "Administrator authorization was refused." : details
            }
        }
    }
}
