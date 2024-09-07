import Foundation
import Virtualization

enum LogLevel: String {
    case Debug = "DEBUG"
    case Error = "ERROR"
    case Info = "INFO"
}

struct VMConfiguration {
    var inConfig: Configuration
    var vmConfig: VZVirtualMachineConfiguration
}

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
        let homePath = "~/"
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

    func resolve(path: String, args: Arguments) -> URL {
        let directories = self.resolvable(args: args)
        for key in directories.keys {
            let resolved = self.resolvePath(path: path, prefix: key, with: directories[key]!)
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
    var port: UInt32
    var deadline: UInt32
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
    var path: String
    var readonly: Bool?
}

struct Arguments {
    static let pathSep = "/"

    var verbose: Bool
    var quiet: Bool
    var verify: Bool
    var config: String
    var graphical: Bool
    var pwd: String?

    func readJSON() -> Configuration {
        do {
            if (self.config == "") {
                fatalError("no JSON configuration file given")
            }
            let text: String
            if (self.config == "-") {
                var lines = Array<String>()
                while let line = readLine() {
                    lines.append(line)
                }
                text = lines.joined(separator: "\n")
            } else {
                text = try String(contentsOfFile: self.config)
            }
            if let data = text.data(using: .utf8) {
                do {
                    let config: Configuration = try JSONDecoder().decode(Configuration.self, from: data)
                    return config
                } catch {
                    print(error.localizedDescription)
                }
            }
            fatalError("failed to parse JSON file: \(self.config)")
        } catch {
            fatalError("unable to read JSON from file: \(self.config)")
        }
    }
    func log(level: LogLevel, message: String) {
        if (self.quiet) {
            return
        }
        if (level == LogLevel.Debug && !self.verbose) {
            return
        }
        print("[\(level)] \(message)")
    }
    mutating func setDirectory() {
        let parts = self.config.split(separator: Arguments.pathSep.first!)
        let pwd = parts[0...parts.count-2].joined(separator: Arguments.pathSep)
        self.pwd = Arguments.pathSep + pwd + Arguments.pathSep 
    }
}

enum VMError: Error {
    case runtimeError(String)
}

struct VM {
    let configOption = "--config"
    let helpOption = "--help"
    let verifyOption = "--verify"
    let verboseOption = "--verbose"
    let quietOption = "--quiet"
    let minMemory: UInt64 = 128
    let serialFull = "full"

    private func flags() -> Array<String> {
        return [configOption, verifyOption, helpOption, verboseOption, quietOption]
    }

    private func createGraphicsDeviceConfiguration(width: Int, height: Int) -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: height)
        ]

        return graphicsDevice
    }

    private func createConsoleConfiguration(full: Bool) -> VZSerialPortConfiguration {
        let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
        let inputFileHandle = FileHandle.standardInput
        let outputFileHandle = FileHandle.standardOutput
        if (full) {
            var attributes = termios()
            tcgetattr(inputFileHandle.fileDescriptor, &attributes)
            attributes.c_iflag &= ~tcflag_t(ICRNL)
            attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
            tcsetattr(inputFileHandle.fileDescriptor, TCSANOW, &attributes)
        }
        let stdioAttachment = VZFileHandleSerialPortAttachment(fileHandleForReading: inputFileHandle,
                                                               fileHandleForWriting: outputFileHandle)
        consoleConfiguration.attachment = stdioAttachment
        return consoleConfiguration
    }

    private func setupMachineIdentifier(cfg: Configuration, path: String, args: Arguments) throws -> VZGenericMachineIdentifier? {
        let resolved = cfg.resolve(path: path, args: args)
        if (pathExists(path: resolved)) {
            let read = try Data(contentsOf: resolved)
            let id = VZGenericMachineIdentifier(dataRepresentation: read)
            return id
        }

        let machineIdentifier = VZGenericMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: resolved)
        return machineIdentifier
    }

    private func pathExists(path: URL) -> Bool {
        return FileManager.default.fileExists(atPath: path.path)
    }

    private func getVMConfig(cfg: Configuration, args: Arguments) throws -> VMConfiguration {
        let boot = cfg.boot
        if (boot.linux == nil && boot.efi == nil) {
            throw VMError.runtimeError("linux OR efi boot must be set")
        }
        if (boot.linux != nil && boot.efi != nil) {
            throw VMError.runtimeError("linux AND efi boot can NOT be set")
        }
        let config = VZVirtualMachineConfiguration()
        let machineIdentifier = (cfg.identifier ?? "")
        if (machineIdentifier != "") {
            let platform = VZGenericPlatformConfiguration()
            let machine = try setupMachineIdentifier(cfg: cfg, path: machineIdentifier, args: args)
            if (machine == nil) {
                throw VMError.runtimeError("unable to setup machine identifier")
            }
            platform.machineIdentifier = machine!
            config.platform = platform
        }
        if (boot.linux != nil) {
            let opts = cfg.boot.linux!
            if (opts.kernel == "") {
                throw VMError.runtimeError("kernel path is not set")
            }

            let kernelURL = cfg.resolve(path: opts.kernel, args: args)
            let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            let cmdline = (opts.cmdline ?? "console=hvc0")
            let initrd = (opts.initrd ?? "")
            bootLoader.commandLine = cmdline
            if (initrd != "") {
                bootLoader.initialRamdiskURL = cfg.resolve(path: initrd, args: args)
            }
            args.log(level: LogLevel.Debug, message: "configuring - kernel: \(opts.kernel), initrd: \(initrd), cmdline: \(cmdline)")
            config.bootLoader = bootLoader
        } else {
            let opts = cfg.boot.efi!
            let efi = opts.store
            if (efi == "") {
                throw VMError.runtimeError("efi store not set")
            }
            let resolved = cfg.resolve(path: efi, args: args)
            let creating = !pathExists(path: resolved)
            let loader = VZEFIBootLoader()
            if (creating) {
                loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: resolved, options: [])
            } else {
                loader.variableStore = VZEFIVariableStore(url: resolved)
            }
            config.bootLoader = loader
        }
        config.cpuCount = cfg.resources.cpus
        let memory = (cfg.resources.memory ?? minMemory)
        if (memory < minMemory) {
            throw VMError.runtimeError("not enough memory for VM")
        }
        config.memorySize = memory * 1024*1024
        let graphical = args.graphical || args.verify
        if (graphical) {
            let graphics = cfg.graphics ?? GraphicsConfiguration(width: 1280, height: 720)
            if (graphics.width <= 0 || graphics.height <= 0) {
                throw VMError.runtimeError("graphics height/width must be > 0")
            }
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            config.graphicsDevices = [createGraphicsDeviceConfiguration(width: graphics.width, height: graphics.height)]
        }

        var useSerial = true
        if (args.verify || args.graphical) {
            useSerial = false
        }
        if (useSerial) {
            let serialMode = (cfg.serial ?? serialFull)
            var full = true
            var attach = true
            switch (serialMode) {
                case "none":
                    attach = false
                case serialFull:
                    args.log(level: LogLevel.Info, message: "serial console in full mode, this may interfere with normal stdin/stdout")
                case "raw":
                    args.log(level: LogLevel.Debug, message: "attaching raw serial console")
                    full = false
                default:
                    throw VMError.runtimeError("unknown serial mode: \(serialMode)")
            }
            if (attach) {
                config.serialPorts = [createConsoleConfiguration(full: full)]
            }
        }

        var networkConfigs = Array<VZVirtioNetworkDeviceConfiguration>()
        var networkAttachments = Set<String>()
        for network in (cfg.networks ?? Array<NetworkConfiguration>()) {
            let networkConfig = VZVirtioNetworkDeviceConfiguration()
            var networkIdentifier = ""
            var networkIdentifierMessage = ""
            switch (network.mode) {
            case "nat":
                let mac = (network.mac ?? "")
                if (mac != "") {
                    guard let addr = VZMACAddress(string: mac) else {
                        throw VMError.runtimeError("invalid MAC address: \(mac)")
                    }
                    networkConfig.macAddress = addr
                }
                networkIdentifier = mac
                networkIdentifierMessage = "multiple NAT devices using same or empty MAC is not allowed \(mac)"
                networkConfig.attachment = VZNATNetworkDeviceAttachment()
                args.log(level: LogLevel.Debug, message: "NAT network attached (mac? \(mac))")
            default:
                throw VMError.runtimeError("unknown network mode: \(network.mode)")
            }
            if (networkAttachments.contains(networkIdentifier)) {
                throw VMError.runtimeError(networkIdentifierMessage)
            }
            networkAttachments.insert(networkIdentifier)
            networkConfigs.append(networkConfig)
        }
        config.networkDevices = networkConfigs
        
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        var allStorage = Array<VZStorageDeviceConfiguration>()
        for disk in (cfg.disks ?? Array<DiskConfiguration>()) {
            if (disk.path == "") {
                throw VMError.runtimeError("invalid disk, empty path")
            }
            let ro = (disk.readonly ?? false)
            guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: cfg.resolve(path: disk.path, args: args), readOnly: ro) else {
                throw VMError.runtimeError("invalid disk: \(disk.path)")
            }
            switch (disk.mode) {
                case "usb":
                    allStorage.append(VZUSBMassStorageDeviceConfiguration(attachment: diskObject))
                case "block":
                    allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
            case "nvme":
                if #available(macOS 14, *) {
                    allStorage.append(VZNVMExpressControllerDeviceConfiguration(attachment: diskObject))
                } else {
                    throw VMError.runtimeError("nvme disk mode not available in macOS version")
                }
                default:
                    throw VMError.runtimeError("invalid disk mode")
            }
            args.log(level: LogLevel.Debug, message: "attaching disk: \(disk.path), ro: \(ro), mode: \(disk.mode)")
        }
        config.storageDevices = allStorage

        let shares = (cfg.shares ?? Dictionary<String, ShareConfiguration>())
        if (shares.count > 0) {
            var allShares = Array<VZVirtioFileSystemDeviceConfiguration>()
            for key in shares.keys {
                do {
                    try VZVirtioFileSystemDeviceConfiguration.validateTag(key)
                } catch {
                    throw VMError.runtimeError("invalid tag: \(key)")
                }
                guard let local = shares[key] else {
                    throw VMError.runtimeError("unable to read share configuration: \(key)")
                }
                if (local.path == "") {
                    throw VMError.runtimeError("empty share path: \(key)")
                }
                let ro = (local.readonly ?? false)
                let directoryShare = VZSharedDirectory(url: cfg.resolve(path: local.path, args: args), readOnly: ro)
                let singleDirectory = VZSingleDirectoryShare(directory: directoryShare)
                let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: key)
                shareConfig.share = singleDirectory
                allShares.append(shareConfig)
                args.log(level: LogLevel.Debug, message: "sharing: \(key) -> \(local.path), ro: \(ro)")
             }
             config.directorySharingDevices = allShares
        }
        if (cfg.entropy ?? true) {
            let entropy = VZVirtioEntropyDeviceConfiguration()
            config.entropyDevices = [entropy]
        }
        if (cfg.time != nil) {
            config.socketDevices.append(VZVirtioSocketDeviceConfiguration())
        }
        return VMConfiguration(inConfig: cfg, vmConfig: config)
    }

    private func usage(message: String) {
        print("vfu:")
        for flag in flags() {
            var indent = ""
            var extra = ""
            switch (flag) {
                case configOption:
                    extra = "<configuration file> ('-' for stdin)"
                case verifyOption:
                    extra = "verify the configuration only"
                    indent = "  "
                case helpOption:
                    extra = "display this help text"
                case verboseOption:
                    extra = "include verbose log output"
                case quietOption:
                    extra = "disable all log output"
                default:
                    break
            }
            var spacing = ""
            var idx = 15 - indent.count
            while (idx > flag.count) {
                spacing = "\(spacing) "
                idx -= 1
            }
            print("  \(indent)\(flag)\(spacing)\(extra)")
        }
        print("")
        if (message != "") {
            fatalError(message)
        }
    }

    func parseArguments() -> Arguments? {
        var jsonConfig = ""
        var verifyMode = false
        var isVerbose = false
        var isQuiet = false
        let arguments = CommandLine.arguments.count - 1
        var matched = 0
        for flag in flags() {
            var pos = 0
            var found = false
            for arg in CommandLine.arguments {
                if arg == flag {
                    if (found) {
                        fatalError("\(flag) already parsed")
                    }
                    matched += 1
                    found = true
                    switch (flag) {
                        case configOption:
                            if (pos == arguments) {
                                fatalError("config file not specified")
                            }
                            jsonConfig = CommandLine.arguments[pos+1]
                            matched += 1
                            pos += 1
                        case helpOption:
                            usage(message: "")
                            return nil
                        case verboseOption:
                            isVerbose = true
                        case quietOption:
                            isQuiet = true
                        case verifyOption:
                            verifyMode = true
                        default:
                            usage(message: "unexpected flag: \(flag)")
                    }
                }
                pos += 1
            }
        }
        if (matched != arguments) {
            usage(message: "unknown flags given")
        }
        if (isVerbose && isQuiet) {
            usage(message: "can not specify verbose and quiet together")
        }
        return Arguments(verbose: isVerbose, quiet: isQuiet, verify: verifyMode, config: jsonConfig, graphical: false)
    }

    func createConfiguration(args: Arguments) -> VMConfiguration? {
        let object = args.readJSON()
        if (object.resources.cpus <= 0) {
            fatalError("cpu count must be > 0")
        }

        do {
            let config = try getVMConfig(cfg: object, args: args)
            try config.vmConfig.validate()
            if (args.verify) {
                return nil
            }
            return config
        } catch VMError.runtimeError(let errorMessage) {
            fatalError("vm configuration error: \(errorMessage)")
        } catch (let errorMessage) {
            fatalError("unexpected configuration error: \(errorMessage)")
        }
    }

    func runCLI(config: VMConfiguration, args: Arguments) {
        let queue = DispatchQueue(label: "vfu queue")
        let vm = VZVirtualMachine(configuration: config.vmConfig, queue: queue)
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start")
            }
        }
        args.log(level: LogLevel.Info, message: "vm ready")
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        args.log(level: LogLevel.Info, message: "vm initialized")
        sleep(1)
        var clockSleep = 0
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            clockSleep += 1
            sleep(1)
            queue.sync {
                if (handleClockSync(since: clockSleep, vm: vm, config: config, log: args.log)) {
                    clockSleep = 0
                }
            }
        }
        args.log(level: LogLevel.Debug, message: "exiting")
    }
}

func handleClockSync(since: Int, vm: VZVirtualMachine, config: VMConfiguration, log: @escaping (_: LogLevel, _: String) ->()) -> Bool {
    if (config.inConfig.time == nil) {
        return false
    }
    if (since < config.inConfig.time!.deadline ) {
        return false
    }
    
    log(LogLevel.Debug, "time sync inprogress")
    let socket = vm.socketDevices[0] as? VZVirtioSocketDevice
    socket?.connect(toPort: config.inConfig.time!.port) {(result) in
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
