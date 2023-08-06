import Foundation
import Virtualization

let configOption = "--config"
let helpOption = "--help"
let verifyOption = "--verify"
let versionOption = "--version"
let configFileTemplate = "<configuration file>"
let minMemory: UInt64 = 128
let readonlyJSONKey = "readonly"
let networkModeJSONKey = "mode"
let networkMACJSONKey = "mac"
let diskPathJSONKey = "path"
let sharePathJSONKey = "path"
let kernelJSONKey = "kernel"
let initrdJSONKey = "initrd"
let cpuJSONKey = "cpus"
let memJSONKey = "memory"
let networkJSONKey = "network"
let commandLineJSONKey = "cmdline"
let shareJSONKey = "shares"
let diskJSONKey = "disks"
let pathSeparator = "/"
let resolveHomeIndicator = "~" + pathSeparator
let topLevelJSONKeys: Set<String> = [kernelJSONKey,
                                     initrdJSONKey,
                                     cpuJSONKey,
                                     memJSONKey,
                                     shareJSONKey,
                                     diskJSONKey,
                                     commandLineJSONKey,
                                     networkJSONKey]
let diskJSONKeys: Set<String> = [readonlyJSONKey, diskPathJSONKey]
let shareJSONKeys: Set<String> = [sharePathJSONKey, readonlyJSONKey]
let networkJSONKeys: Set<String> = [networkModeJSONKey, networkMACJSONKey]

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

func checkKeys(keys: Array<String>, allowed: Set<String>) throws {
    for key in keys {
        if (!allowed.contains(key)) {
            throw VMError.runtimeError("unknown JSON configuration key: \(key)")
        }
    }
}

func isReadOnly(data: Dictionary<String, String>) -> Bool {
    return (data[readonlyJSONKey] ?? "") == "yes"
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

func  getVMConfig(memoryMB: UInt64,
                  numCPUs: Int,
                  commandLine: String,
                  kernelPath: String,
                  initrdPath: String,
                  disks: Array<Dictionary<String, String>>,
                  shares: Dictionary<String, Dictionary<String, String>>,
                  networking: Array<Dictionary<String, String>>) throws -> VZVirtualMachineConfiguration {
    let kernelURL = resolveUserHome(path: kernelPath)
    let bootLoader: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    bootLoader.commandLine = commandLine
    if (initrdPath != "") {
        bootLoader.initialRamdiskURL = resolveUserHome(path: initrdPath)
    }

    print("configuring - kernel: \(kernelPath), initrd: \(initrdPath), cmdline: \(commandLine)")
    let config = VZVirtualMachineConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = numCPUs
    config.memorySize = memoryMB * 1024*1024
    config.serialPorts = [createConsoleConfiguration()]

    var networkConfigs = Array<VZVirtioNetworkDeviceConfiguration>()
    var networkAttachments = Set<String>()
    for network in networking {
        try checkKeys(keys: Array(network.keys), allowed: networkJSONKeys)
        let networkMode = (network[networkModeJSONKey] ?? "")
        let networkConfig = VZVirtioNetworkDeviceConfiguration()
        var networkIdentifier = ""
        var networkIdentifierMessage = ""
        switch (networkMode) {
        case "nat":
            let networkMAC = (network[networkMACJSONKey] ?? "")
            if (networkMAC != "") {
                guard let addr = VZMACAddress(string: networkMAC) else {
                    throw VMError.runtimeError("invalid MAC address: \(networkMAC)")
                }
                networkConfig.macAddress = addr
            }
            networkIdentifier = networkMAC
            networkIdentifierMessage = "multiple NAT devices using same or empty MAC is not allowed \(networkMAC)"
            networkConfig.attachment = VZNATNetworkDeviceAttachment()
            print("NAT network attached (mac? \(networkMAC))")
        default:
            throw VMError.runtimeError("unknown network mode: \(networkMode)")
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
    for disk in disks {
        try checkKeys(keys: Array(disk.keys), allowed: diskJSONKeys)
        let diskPath = (disk[diskPathJSONKey] ?? "")
        if (diskPath == "") {
            throw VMError.runtimeError("invalid disk, empty path")
        }
        guard let diskObject = try? VZDiskImageStorageDeviceAttachment(url: resolveUserHome(path: diskPath), readOnly: isReadOnly(data: disk)) else {
            throw VMError.runtimeError("invalid disk: \(diskPath)")
        }
        allStorage.append(VZVirtioBlockDeviceConfiguration(attachment: diskObject))
        print("attaching disk: \(diskPath)")
    }
    config.storageDevices = allStorage

    if (shares.count > 0) {
        var allShares = Array<VZVirtioFileSystemDeviceConfiguration>()
        for key in shares.keys {
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(key)
            } catch {
                throw VMError.runtimeError("invalid tag: \(key)")
            }
            let local = try readShare(key: key, shares: shares)
            try checkKeys(keys: Array(local.keys), allowed: shareJSONKeys)
            let sharePath = (local[sharePathJSONKey] ?? "")
            if (sharePath == "") {
                throw VMError.runtimeError("empty share path: \(key)")
            }
            let directoryShare = VZSharedDirectory(url:resolveUserHome(path: sharePath), readOnly: isReadOnly(data: local))
            let singleDirectory = VZSingleDirectoryShare(directory: directoryShare)
            let shareConfig = VZVirtioFileSystemDeviceConfiguration(tag: key)
            shareConfig.share = singleDirectory
            allShares.append(shareConfig)
            print("sharing: \(key) -> \(sharePath)")
         }
         config.directorySharingDevices = allShares
    }
    return config
}

func readShare(key: String, shares: Dictionary<String, Dictionary<String, String>>) throws -> Dictionary<String, String> {
    guard let local = shares[key] else {
        throw VMError.runtimeError("unable to read share configuration: \(key)")
    }
    return local
}

func usage(invalidArgument: String) {
    print("swiftvf:\n  \(configOption) \(configFileTemplate) [REQUIRED]\n  \(helpOption)\n  \(versionOption)\n  \(verifyOption) [after \(configOption) \(configFileTemplate)]\n")
    if (invalidArgument != "") {
        fatalError("invalid argument")
    }
}

func readJSON(path: String) -> [String: Any]? {
    do {
        let text = try String(contentsOfFile: path)
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                print(error.localizedDescription)
            }
        }
        return nil
    } catch {
        fatalError("unable to read JSON from file \(path)")
    }
}

func run() {
    var jsonConfig = ""
    var idx = 0
    var verifyMode = false
    for argument in CommandLine.arguments {
        switch (idx) {
        case 0:
            break
        case 1:
            switch (argument) {
            case configOption:
                break
            case helpOption:
                usage(invalidArgument: "")
                return
            case versionOption:
                let vers = version()
                print("\(vers)")
                return
            default:
                usage(invalidArgument: argument)
            }
        case 2:
            jsonConfig = argument
        case 3:
            if (argument != verifyOption) {
                usage(invalidArgument: argument)
            }
            verifyMode = true
        default:
            fatalError("unknown argument: \(argument)")
        }
        idx += 1
    }
    if (jsonConfig == "") {
        fatalError("no JSON config given")
    }
    let object = (readJSON(path: jsonConfig) ?? Dictionary())
    let kernel = ((object[kernelJSONKey] as? String) ?? "")
    if (kernel == "") {
        fatalError("kernel path is not set")
    }
    let initrd = ((object[initrdJSONKey] as? String) ?? "")
    let networks = ((object[networkJSONKey] as? Array<Dictionary<String, String>>) ?? Array<Dictionary<String, String>>())
    let cmd = ((object[commandLineJSONKey] as? String) ?? "console=hvc0")
    let cpus = ((object[cpuJSONKey] as? Int) ?? 1)
    if (cpus <= 0) {
        fatalError("cpu count must be > 0")
    }
    let mem = ((object[memJSONKey] as? UInt64) ?? minMemory)
    if (mem < minMemory) {
        fatalError("memory must be >= \(minMemory)")
    }
    let disks = ((object[diskJSONKey] as? Array<Dictionary<String, String>>) ?? Array<Dictionary<String, String>>())
    let shares = ((object[shareJSONKey] as? Dictionary<String, Dictionary<String, String>>) ?? Dictionary<String, Dictionary<String, String>>())

    do {
        try checkKeys(keys: Array(object.keys), allowed: topLevelJSONKeys)
        let config = try getVMConfig(memoryMB: mem, numCPUs: cpus, commandLine: cmd, kernelPath: kernel, initrdPath: initrd, disks: disks, shares: shares, networking: networks)
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
