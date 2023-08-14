import Foundation
import Virtualization

struct Configuration: Decodable {
    var boot: BootConfiguration
    var resources: ResourceConfiguration
    var identifier: String?
    var serial: String?
    var disks: Array<DiskConfiguration>?
    var networks: Array<NetworkConfiguration>?
    var shares: Dictionary<String, ShareConfiguration>?
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
    let pathSep = "/"

    var verbose: Bool
    var verify: Bool
    var config: String
    var graphical: Bool
    
    private func resolvable() -> Dictionary<String, URL> {
        var dirs = Dictionary<String, URL>()
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs["~/"] = home
        dirs["$HOME/"] = home
        let path = self.config.split(separator: pathSep)
        if (path.count > 1) {
            let pwd = path[0...path.count-2].joined(separator: pathSep)
            dirs["$PWD/"] = URL(fileURLWithPath: pathSep + pwd)
        }
        return dirs
    }
    
    func resolve(path: String) -> URL {
        let directories = self.resolvable()
        for key in directories.keys {
            if (!path.hasPrefix(key)) {
                continue
            }
            var resolveTo = directories[key]!
            self.log(message: "resolving: \(path) with \(key) -> \(resolveTo)")
            if (path == key) {
                return resolveTo
            }
            let sub = path.dropFirst(key.count)
            resolveTo.append(path: String(sub))
            self.log(message: "resolved to: \(resolveTo)")
            return resolveTo
        }
        return URL(fileURLWithPath: path)
    }

    func readJSON() -> Configuration {
        do {
            if (self.config == "") {
                fatalError("no JSON configuration file given")
            }
            let text = try String(contentsOfFile: self.config)
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
    func log(message: String) {
        if (self.verbose) {
            print(message)
        }
    }
}

enum VMError: Error {
    case runtimeError(String)
}

struct VM {
    let configOption = "--config"
    let helpOption = "--help"
    let verifyOption = "--verify"
    let versionOption = "--version"
    let verboseOption = "--verbose"
    let minMemory: UInt64 = 128
    let serialFull = "full"

    private func flags() -> Array<String> {
        return [configOption, verifyOption, helpOption, versionOption, verboseOption]
    }

    private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
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

    private func setupMachineIdentifier(path: String) throws -> VZGenericMachineIdentifier? {
        if (pathExists(path: path)) {
            let read = try Data(contentsOf: URL(fileURLWithPath: path))
            let id = VZGenericMachineIdentifier(dataRepresentation: read)
            return id
        }

        let machineIdentifier = VZGenericMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: path))
        return machineIdentifier
    }

    private func pathExists(path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    private func getVMConfig(cfg: Configuration, args: Arguments) throws -> VZVirtualMachineConfiguration {
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
            let machine = try setupMachineIdentifier(path: machineIdentifier)
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

            let kernelURL = args.resolve(path: opts.kernel)
            let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            let cmdline = (opts.cmdline ?? "console=hvc0")
            let initrd = (opts.initrd ?? "")
            bootLoader.commandLine = cmdline
            if (initrd != "") {
                bootLoader.initialRamdiskURL = args.resolve(path: initrd)
            }
            args.log(message: "configuring - kernel: \(opts.kernel), initrd: \(initrd), cmdline: \(cmdline)")
            config.bootLoader = bootLoader
        } else {
            let opts = cfg.boot.efi!
            let efi = opts.store
            if (efi == "") {
                throw VMError.runtimeError("efi store not set")
            }
            let creating = !pathExists(path: efi)
            let loader = VZEFIBootLoader()
            let resolved = args.resolve(path: efi)
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
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            config.graphicsDevices = [createGraphicsDeviceConfiguration()]
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
                    args.log(message: "NOTICE: serial console in full mode, this may interfere with normal stdin/stdout")
                case "raw":
                    args.log(message: "attaching raw serial console")
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
                args.log(message: "NAT network attached (mac? \(mac))")
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
            guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: args.resolve(path: disk.path), readOnly: ro) else {
                throw VMError.runtimeError("invalid disk: \(disk.path)")
            }
            switch (disk.mode) {
                case "usb":
                    allStorage.append(VZUSBMassStorageDeviceConfiguration(attachment: diskObject))
                case "block":
                    allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
                default:
                    throw VMError.runtimeError("invalid disk mode")
            }
            args.log(message: "attaching disk: \(disk.path), ro: \(ro), mode: \(disk.mode)")
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
                let directoryShare = VZSharedDirectory(url:args.resolve(path: local.path), readOnly: ro)
                let singleDirectory = VZSingleDirectoryShare(directory: directoryShare)
                let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: key)
                shareConfig.share = singleDirectory
                allShares.append(shareConfig)
                args.log(message: "sharing: \(key) -> \(local.path), ro: \(ro)")
             }
             config.directorySharingDevices = allShares
        }
        return config
    }

    private func usage(message: String) {
        print("vfu:")
        for flag in flags() {
            var indent = ""
            var extra = ""
            switch (flag) {
                case configOption:
                    extra = "<configuration file>"
                case verifyOption:
                    extra = "verify the configuration only"
                    indent = "  "
                case helpOption:
                    extra = "display this help text"
                case verboseOption:
                    extra = "include verbose output"
                case versionOption:
                    extra = "output the version"
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
        vers()
        if (message != "") {
            fatalError(message)
        }
    }

    private func vers() {
        let v = versionHash()
        print("version: \(v)")
    }

    func parseArguments() -> Arguments? {
        var jsonConfig = ""
        var verifyMode = false
        var isVerbose = false
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
                        case versionOption:
                            vers()
                            return nil
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
        return Arguments(verbose: isVerbose, verify: verifyMode, config: jsonConfig, graphical: false)
    }

    func createConfiguration(args: Arguments) -> VZVirtualMachineConfiguration? {
        let object = args.readJSON()
        if (object.resources.cpus <= 0) {
            fatalError("cpu count must be > 0")
        }

        do {
            let config = try getVMConfig(cfg: object, args: args)
            try config.validate()
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

    func runCLI(config: VZVirtualMachineConfiguration, args: Arguments) {
        let queue = DispatchQueue(label: "vfu queue")
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start")
            }
        }
        args.log(message: "vm ready")
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        args.log(message: "vm initialized")
        sleep(1)
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            sleep(1)
        }
        args.log(message: "exiting")
    }
}
