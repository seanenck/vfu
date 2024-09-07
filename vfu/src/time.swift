import Foundation
import Virtualization

let nanoConvert: UInt64 = 1000000000

enum TimeError: Error {
    case runtimeError(String)
}

func handleClockSync(since: Int, vm: VZVirtualMachine, config: VMConfiguration, log: @escaping (_: LogLevel, _: String) ->()) -> Bool {
    if (config.inConfig.time == nil) {
        return false
    }
    if (since < config.inConfig.time!.qemu.deadline ) {
        return false
    }
    
    log(LogLevel.Debug, "time sync in progress")
    let socket = vm.socketDevices[0] as? VZVirtioSocketDevice
    socket?.connect(toPort: config.inConfig.time!.qemu.port) {(result) in
        switch result {
        case let .failure(error):
            log(LogLevel.Error, "failed to connect to socket with error: \(error)")
        case let .success(conn):
            var handle: FileHandle? = nil
            do {
                handle = FileHandle(fileDescriptor: conn.fileDescriptor)
                let currentTime = try readGuestTime(handle: handle!) / nanoConvert
                let now = UInt64(Date().timeIntervalSince1970)
                let delta = now - currentTime
                log(LogLevel.Debug, "guest: \(currentTime), host: \(now)")
                if (delta > config.inConfig.time!.qemu.delta) {
                    log(LogLevel.Info, "timesync required")
                    let nano = now * nanoConvert
                    let resp = try readResponse(handle: handle!, command: createGuestAgentCommand(command: "guest-set-time", args: "\"time\": \(nano)}"))
                    log(LogLevel.Debug, resp)
                    if (resp.trimmingCharacters(in: .whitespacesAndNewlines) != "{\"return\": {}}") {
                        log(LogLevel.Error, "unexpected response: \(resp)")
                    }
                }
            } catch {
                log(LogLevel.Error, "failed to send/respond: \(error)")
            }
            do {
                conn.close()
                if (handle != nil) {
                    try handle!.close()
                }
            } catch {
                log(LogLevel.Error, "unable to cleanup: \(error)")
            }
        }
    }
    return true
}

private func createGuestAgentCommand(command: String, args: String) -> String {
    return "{\"execute\": \"\(command)\", \"arguments\":{\(args)}}\n"
}

private func readResponse(handle: FileHandle, command: String) throws -> String {
    let data = Data(command.utf8)
    try handle.write(contentsOf: data)
    var reading = true
    var resp = ""
    while (reading) {
        switch try handle.read(upToCount: 1) {
        case let .some(d):
            let str = String(decoding: d, as: UTF8.self)
            if (str.contains("\n")) {
                reading = false
            }
            resp.append(str)
        case .none:
            break
        }
    }
    return resp.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func readGuestTime(handle: FileHandle) throws -> UInt64 {
    let resp = try readResponse(handle: handle, command: createGuestAgentCommand(command: "guest-get-time", args: ""))
    if let data = resp.data(using: .utf8) {
        let map = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if (map == nil) {
            throw TimeError.runtimeError("invalid json response, not a map")
        }
        let r = map!["return"]
        if (r != nil) {
            let time = r as? UInt64
            if (time != nil) {
                return time!
            }
        }
    }
    throw TimeError.runtimeError("unable to parse guest time")
}
