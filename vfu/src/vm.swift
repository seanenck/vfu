import Foundation
import Virtualization

let minMemory: UInt64 = 128
let serialFull = "full"

struct VMConfiguration {
    var inConfig: Configuration
    var vmConfig: VZVirtualMachineConfiguration
}

enum VMError: Error {
    case runtimeError(String)
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
