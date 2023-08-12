import Foundation
import Virtualization

let configOption = "--config"
let helpOption = "--help"
let verifyOption = "--verify"
let versionOption = "--version"
let verboseOption = "--verbose"
let pathSeparator = "/"
let resolveHomeIndicator = "~" + pathSeparator
let minMemory: UInt64 = 128
let serialFull = "full"
let commandLineFlags = [configOption, verifyOption, helpOption, versionOption, verboseOption]

struct Configuration: Decodable {
    var kernel: String
    var initrd: String?
    var cpus: Int
    var cmdline: String?
    var serial: String?
    var memory: UInt64?
    var disks: Array<DiskConfiguration>?
    var networks: Array<NetworkConfiguration>?
    var shares: Dictionary<String, ShareConfiguration>?
}
struct DiskConfiguration: Decodable {
    var path: String
    var readonly: Bool?
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
    var verbose: Bool
    var verify: Bool
    var config: String

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

func createConsoleConfiguration(full: Bool) -> VZSerialPortConfiguration {
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

func resolveUserHome(path: String) -> URL {
    if (!path.hasPrefix(resolveHomeIndicator)) {
        return URL(fileURLWithPath: path)
    }
    let homeDirURL = FileManager.default.homeDirectoryForCurrentUser
    if (path == resolveHomeIndicator) {
        return homeDirURL
    } else {
        var components = homeDirURL.pathComponents
        components.append(String(path.dropFirst(resolveHomeIndicator.count)))
        let pathing = components.joined(separator: pathSeparator)
        return URL(fileURLWithPath: pathing)
    }
}

func getVMConfig(cfg: Configuration, args: Arguments) throws -> VZVirtualMachineConfiguration {
    let kernelURL = resolveUserHome(path: cfg.kernel)
    let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    let cmdline = (cfg.cmdline ?? "console=hvc0")
    let initrd = (cfg.initrd ?? "")
    bootLoader.commandLine = cmdline
    if (initrd != "") {
        bootLoader.initialRamdiskURL = resolveUserHome(path: initrd)
    }
    args.log(message: "configuring - kernel: \(cfg.kernel), initrd: \(initrd), cmdline: \(cmdline)")
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = cfg.cpus
    let memory = (cfg.memory ?? minMemory)
    if (memory < minMemory) {
        throw VMError.runtimeError("not enough memory for VM")
    }
    config.memorySize = (cfg.memory ?? minMemory) * 1024*1024
    if (!args.verify) {
        let serialMode = (cfg.serial ?? serialFull)
        var full = true
        var attach = true
        switch (serialMode) {
            case "none":
                attach = false
                break
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
    var allStorage = Array<VZVirtioBlockDeviceConfiguration>()
    for disk in (cfg.disks ?? Array<DiskConfiguration>()) {
        if (disk.path == "") {
            throw VMError.runtimeError("invalid disk, empty path")
        }
        let ro = (disk.readonly ?? false)
        guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: resolveUserHome(path: disk.path), readOnly: ro) else {
            throw VMError.runtimeError("invalid disk: \(disk.path)")
        }
        allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
        args.log(message: "attaching disk: \(disk.path), ro: \(ro)")
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
            let directoryShare = VZSharedDirectory(url:resolveUserHome(path: local.path), readOnly: ro)
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

func usage(message: String) {
    print("vfu:")
    for flag in commandLineFlags {
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

func vers() {
    let v = version()
    print("version: \(v)")
}

func parseArguments() -> Arguments? {
    var jsonConfig = ""
    var verifyMode = false
    var isVerbose = false
    let arguments = CommandLine.arguments.count - 1
    var matched = 0
    for flag in commandLineFlags {
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
    return Arguments(verbose: isVerbose, verify: verifyMode, config: jsonConfig)
}

func run() {
    let args = parseArguments()
    if (args == nil) {
        return
    }
    let runArgs = args!
    let object = runArgs.readJSON()
    if (object.kernel == "") {
        fatalError("kernel path is not set")
    }
    if (object.cpus <= 0) {
        fatalError("cpu count must be > 0")
    }
    do {
        let config = try getVMConfig(cfg: object, args: runArgs)
        try config.validate()
        if (runArgs.verify) {
            return
        }
        let queue = DispatchQueue(label: "secondary queue")
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start")
            }
        }
        runArgs.log(message: "vm ready")
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        runArgs.log(message: "vm initialized")
        sleep(1)
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            sleep(1)
        }
        runArgs.log(message: "exiting")
    } catch VMError.runtimeError(let errorMessage) {
        fatalError("vm error: \(errorMessage)")
    } catch (let errorMessage) {
        fatalError("error: \(errorMessage)")
    }
}

run()
