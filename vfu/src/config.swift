import Foundation

let isHome = "~/"

struct Configuration: Decodable {

    var env: Dictionary<String, String>?
    var boot: BootConfiguration
    var resources: ResourceConfiguration
    var identifier: String?
    var serial: String?
    var disks: Array<DiskConfiguration>?
    var networks: Array<NetworkConfiguration>?
    var shares: Dictionary<String, ShareConfiguration>?
    var graphics: GraphicsConfiguration?
    var entropy: Bool?
    var time: TimeConfiguration?

    private func resolvable(args: Arguments) -> Dictionary<String, URL> {
        let homePath = isHome
        var dirs = Dictionary<String, URL>()
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs[homePath] = home
        let useEnv = (env ?? Dictionary<String, String>())
        for key in useEnv.keys {
            let path = useEnv[key]!
            let resolved = resolvePath(path: path, prefix: homePath, with: FileManager.default.homeDirectoryForCurrentUser)
            var useKey = key
            if (!useKey.hasPrefix("$")) {
                useKey = "$\(useKey)"
            }
            if (!useKey.hasSuffix("/")) {
                useKey = "\(useKey)/"
            }
            if (resolved == nil) {
                dirs[useKey] = URL(fileURLWithPath: path)
            } else {
                dirs[useKey] = resolved!
            }
        }
        return dirs
    }


    func resolve(path: String, args: Arguments) -> URL {
        let directories = self.resolvable(args: args)
        for key in directories.keys {
            let resolved = resolvePath(path: path, prefix: key, with: directories[key]!)
            if (resolved != nil) {
                return resolved!
            }
        }
        if (args.pwd != nil && path.first! != Arguments.pathSep.first!) {
            return URL(fileURLWithPath: args.pwd! + path)
        }
        return URL(fileURLWithPath: path)
    }
}
struct TimeConfiguration: Decodable {
    var qemu: QemuTimeConfiguration
}
struct QemuTimeConfiguration: Decodable {
    var port: UInt32
    var deadline: UInt32
    var delta: UInt64
}
struct GraphicsConfiguration: Decodable {
    var width: Int
    var height: Int
}
struct ResourceConfiguration: Decodable {
    var cpus: Int
    var memory: UInt64?
}
struct BootConfiguration: Decodable {
    var linux: LinuxBootConfiguration?
    var efi: EFIBootConfiguration?
}
struct LinuxBootConfiguration: Decodable {
    var kernel: String
    var initrd: String?
    var cmdline: String?
}
struct EFIBootConfiguration: Decodable {
    var store: String
}
struct DiskConfiguration: Decodable {
    var path: String
    var readonly: Bool?
    var mode: String
}
struct NetworkConfiguration: Decodable {
    var mac: String?
    var mode: String
}
struct ShareConfiguration: Decodable {
    var name: String?
    var readonly: Bool?
}

private func resolvePath(path: String, prefix: String, with: URL) -> URL? {
    if (path.hasPrefix(prefix)) {
        if (path == prefix) {
            return with
        }
        var to = with
        let sub = path.dropFirst(prefix.count)
        to.append(path: String(sub))
        return to
    }
    return nil
}
