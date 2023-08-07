import Foundation
import Virtualization

let configOption = "--config"
let helpOption = "--help"
let verifyOption = "--verify"
let versionOption = "--version"
let configFileTemplate = "<configuration file>"
let readonlyOn = "yes"
let pathSeparator = "/"
let resolveHomeIndicator = "~" + pathSeparator
let minMemory: UInt64 = 128

struct Configuration: Decodable {
    var kernel: String
    var initrd: String?
    var cpus: Int
    var cmdline: String?
    var memory: UInt64?
    var disks: Array<DiskConfiguration>?
    var networks: Array<NetworkConfiguration>?
    var shares: Dictionary<String, ShareConfiguration>?
}
struct DiskConfiguration: Decodable {
    var path: String
    var readonly: String?
}
struct NetworkConfiguration: Decodable {
    var mac: String?
    var mode: String
}
struct ShareConfiguration: Decodable {
    var path: String
    var readonly: String?
}

enum VMError: Error {
    case runtimeError(String)
}

func createConsoleConfiguration() -> VZSerialPortConfiguration {
    let consoleConfiguration = VZVirtioConsoleDeviceSerialPortConfiguration()
    let inputFileHandle = FileHandle.standardInput
    let outputFileHandle = FileHandle.standardOutput
    var attributes = termios()
    tcgetattr(inputFileHandle.fileDescriptor, &attributes)
    attributes.c_iflag &= ~tcflag_t(ICRNL)
    attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(inputFileHandle.fileDescriptor, TCSANOW, &attributes)
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

func  getVMConfig(cfg: Configuration) throws -> VZVirtualMachineConfiguration {
    let kernelURL = resolveUserHome(path: cfg.kernel)
    let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    let cmdline = (cfg.cmdline ?? "console=hvc0")
    let initrd = (cfg.initrd ?? "")
    bootLoader.commandLine = cmdline
    if (initrd != "") {
        bootLoader.initialRamdiskURL = resolveUserHome(path: initrd)
    }

    print("configuring - kernel: \(cfg.kernel), initrd: \(initrd), cmdline: \(cmdline)")
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = cfg.cpus
    let memory = (cfg.memory ?? minMemory)
    if (memory < minMemory) {
        throw VMError.runtimeError("not enough memory for VM")
    }
    config.memorySize = (cfg.memory ?? minMemory) * 1024*1024
    config.serialPorts = [createConsoleConfiguration()]

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
            print("NAT network attached (mac? \(mac))")
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
        let ro = ((disk.readonly ?? "") == readonlyOn)
        guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: resolveUserHome(path: disk.path), readOnly: ro) else {
            throw VMError.runtimeError("invalid disk: \(disk.path)")
        }
        allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
        print("attaching disk: \(disk.path), ro: \(ro)")
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
            let ro = ((local.readonly ?? "") == readonlyOn)
            let directoryShare = VZSharedDirectory(url:resolveUserHome(path: local.path), readOnly: ro)
            let singleDirectory = VZSingleDirectoryShare(directory: directoryShare)
            let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: key)
            shareConfig.share = singleDirectory
            allShares.append(shareConfig)
            print("sharing: \(key) -> \(local.path), ro: \(ro)")
         }
         config.directorySharingDevices = allShares
    }
    return config
}

func usage(message: String) {
    print("vfu:\n  \(configOption) \(configFileTemplate) [REQUIRED]\n    \(verifyOption)\n  \(helpOption)\n  \(versionOption)\n")
    if (message != "") {
        fatalError(message)
    }
}

func readJSON(path: String) -> Configuration {
    do {
        let text = try String(contentsOfFile: path)
        if let data = text.data(using: .utf8) {
            do {
                let config: Configuration = try JSONDecoder().decode(Configuration.self, from: data)
                return config
            } catch {
                print(error.localizedDescription)
            }
        }
        fatalError("failed to parse JSON file: \(path)")
    } catch {
        fatalError("unable to read JSON from file: \(path)")
    }
}

func run() {
    var jsonConfig = ""
    var inConfig = false
    var verifyMode = false
    var isFirst = true
    for argument in CommandLine.arguments {
        if (isFirst) {
            isFirst = false
            continue
        }
        switch (argument) {
        case configOption:
            if (jsonConfig != "") {
                usage(message: "\(configOption) already specified")
            }
            inConfig = true
        case helpOption:
            usage(message: "")
            return
        case versionOption:
            let vers = version()
            print("\(vers)")
            return
        case verifyOption:
            if verifyMode {
                usage(message: "\(verifyOption) already specified")
            }
            verifyMode = true
        default:
            if (inConfig) {
                jsonConfig = argument
                inConfig = false
            } else {
                usage(message: "unknown argument: \(argument)")
            }
        }
    }
    if (jsonConfig == "" || inConfig) {
        fatalError("no JSON config given")
    }
    let object = readJSON(path: jsonConfig)
    if (object.kernel == "") {
        fatalError("kernel path is not set")
    }
    if (object.cpus <= 0) {
        fatalError("cpu count must be > 0")
    }
    do {
        let config = try getVMConfig(cfg: object)
        try config.validate()
        if (verifyMode) {
            return
        }
        let queue = DispatchQueue(label: "secondary queue")
        let vm = VZVirtualMachine(configuration: config, queue: queue)
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start")
            }
        }
        print("vm ready")
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        print("vm initialized")
        sleep(1)
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            sleep(1)
        }
    } catch VMError.runtimeError(let errorMessage) {
        fatalError("vm error: \(errorMessage)")
    } catch (let errorMessage) {
        fatalError("error: \(errorMessage)")
    }
}

run()
