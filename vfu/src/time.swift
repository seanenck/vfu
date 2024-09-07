import Foundation
import Virtualization

func handleClockSync(since: Int, vm: VZVirtualMachine, config: VMConfiguration, log: @escaping (_: LogLevel, _: String) ->()) -> Bool {
    if (config.inConfig.time == nil) {
        return false
    }
    if (since < config.inConfig.time!.qemu.deadline ) {
        return false
    }
    
    log(LogLevel.Debug, "time sync inprogress")
    let socket = vm.socketDevices[0] as? VZVirtioSocketDevice
    socket?.connect(toPort: config.inConfig.time!.qemu.port) {(result) in
        switch result {
        case let .failure(error):
            log(LogLevel.Error, "failed to connect to socket with error: \(error)")
        case let .success(conn):
            let seconds = Int(Date().timeIntervalSince1970)
            let command = "{\"execute\": \"guest-set-time\", \"arguments\":{\"time\": \(seconds)000000000}}\n"
            let data = Data(command.utf8)
            let handle = FileHandle(fileDescriptor: conn.fileDescriptor)
            do {
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
                log(LogLevel.Debug, resp)
                if (resp.trimmingCharacters(in: .whitespacesAndNewlines) != "{\"return\": {}}") {
                    log(LogLevel.Error, "unexpected response: \(resp)")
                }
            } catch {
                log(LogLevel.Error, "failed to send/respond: \(error)")
            }
        }
    }
    return true
}
