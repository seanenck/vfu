import Foundation
import Virtualization

let MIN_MEMORY: UInt64 = 128;

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


func is_read_only(data: Dictionary<String, String>) -> Bool {
    let readonly = (data["readonly"] ?? "");
    return readonly == "yes";
}

func  getVMConfig(mem_size_mb: UInt64,
                  nr_cpus: Int,
                  cmdline: String,
                  kernel_path: String,
                  initrd_path: String,
                  disks: Array<Dictionary<String, String>>,
                  shares: Dictionary<String, Dictionary<String, String>>,
                  mac_address: String) throws -> VZVirtualMachineConfiguration {
    let kernelURL = URL(fileURLWithPath: kernel_path);
    let lbl: VZLinuxBootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
    lbl.commandLine = cmdline;
    if (initrd_path != "") {
        lbl.initialRamdiskURL = URL(fileURLWithPath: initrd_path);
    }

    print("configuring - kernel: \(kernel_path), initrd: \(initrd_path), cmdline: \(cmdline), mac: \(mac_address)");
    let config = VZVirtualMachineConfiguration();
    config.bootLoader = lbl;
    config.cpuCount = nr_cpus;
    config.memorySize = mem_size_mb * 1024*1024;
    config.serialPorts = [createConsoleConfiguration()];

    let nda = VZNATNetworkDeviceAttachment();
    let net_conf = VZVirtioNetworkDeviceConfiguration()
    if (mac_address != "") {
        guard let addr = VZMACAddress(string: mac_address) else {
            throw VMError.runtimeError("invalid MAC address: \(mac_address)");
        }
        net_conf.macAddress = addr;
    }
    net_conf.attachment = nda;
    config.networkDevices = [net_conf];
    
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()];
    var all_storage = Array<VZVirtioBlockDeviceConfiguration>();
    for disk in disks {
        let disk_path = (disk["path"] ?? "");
        if (disk_path == "") {
            throw VMError.runtimeError("invalid disk, empty path");
        }
        let disk_url = URL(fileURLWithPath: disk_path);
        guard let disk_obj = try? VZDiskImageStorageDeviceAttachment(url: disk_url, readOnly: is_read_only(data: disk)) else {
            throw VMError.runtimeError("invalid disk: \(disk_path)");
        }
        all_storage.append(VZVirtioBlockDeviceConfiguration(attachment: disk_obj));
        print("attaching disk: \(disk_path)")
    }
    config.storageDevices = all_storage;

    if (shares.count > 0) {
        var all_shares = Array<VZVirtioFileSystemDeviceConfiguration>();
        for key in shares.keys {
            guard let local = shares[key] else {
                throw VMError.runtimeError("unable to read share data");
            }
            let share_path = (local["path"] ?? "");
            if (share_path == "") {
                throw VMError.runtimeError("empty share path: \(key)");
            }
            let share_url = URL(fileURLWithPath: share_path);
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(key)
            } catch {
                throw VMError.runtimeError("invalid tag: \(key)");
            }
            let dir_share = VZSharedDirectory(url:share_url, readOnly: is_read_only(data: local));
            let single_dir = VZSingleDirectoryShare(directory: dir_share);
            let share_config = VZVirtioFileSystemDeviceConfiguration(tag: key);
            share_config.share = single_dir;
            all_shares.append(share_config);
            print("sharing: \(key) -> \(share_path)");
         }
         config.directorySharingDevices = all_shares;
    }
    return config;
}

func usage() {
     print("swiftvf:\n  -c/-config <configuration file (json)> [REQUIRED]\n  -h/-help\n");
}

func readJSON(path: String) -> [String: Any]? {
    do {
        let text = try String(contentsOfFile: path);
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                print(error.localizedDescription)
            }
        }
        return nil
    } catch {
        fatalError("unable to read JSON from file \(path)");
    }
}

func run() {
    var json_config = "";
    var idx = 0;
    for argument in CommandLine.arguments {
        switch (idx) {
        case 0:
            break;
        case 1:
            if (argument != "-c" && argument != "-config") {
                if (argument == "-help" || argument == "-h") {
                    usage();
                    return;
                }
                fatalError("invalid argument: \(argument)");
            }
        case 2:
            json_config = argument;
        default:
            fatalError("unknown argument: \(argument)");
        }
        idx += 1;
    }
    if (json_config == "") {
        fatalError("no JSON config given");
    }
    let object = (readJSON(path: json_config) ?? Dictionary())
    let kernel = ((object["kernel"] as? String) ?? "");
    if (kernel == "") {
        fatalError("kernel path is not set");
    }
    let initrd = ((object["initrd"] as? String) ?? "");
    let mac = ((object["mac"] as? String) ?? "");
    let cmd = ((object["cmdline"] as? String) ?? "console=hvc0");
    let cpus = ((object["cpus"] as? Int) ?? 1);
    if (cpus <= 0) {
        fatalError("cpu count must be > 0");
    }
    let mem = ((object["memory"] as? UInt64) ?? MIN_MEMORY);
    if (mem < MIN_MEMORY) {
        fatalError("memory must be >= \(MIN_MEMORY)");
    }
    let disks = ((object["disks"] as? Array<Dictionary<String, String>>) ?? Array<Dictionary<String, String>>());
    let shares = ((object["shares"] as? Dictionary<String, Dictionary<String, String>>) ?? Dictionary<String, Dictionary<String, String>>());

    do {
        let config = try getVMConfig(mem_size_mb: mem, nr_cpus: cpus, cmdline: cmd, kernel_path: kernel, initrd_path: initrd, disks: disks, shares: shares, mac_address: mac);
        try config.validate()
        let queue = DispatchQueue(label: "secondary queue");
        let vm = VZVirtualMachine(configuration: config, queue: queue);
        queue.sync{
            if (!vm.canStart) {
                fatalError("vm can not start");
            }
        }
        print("vm ready");
        queue.sync{
            vm.start(completionHandler: { (result) in
                if case let .failure(error) = result {
                    fatalError("virtual machine failed to start with \(error)")
                }
            })
        }
        print("vm initialized");
        sleep(1)
        while (vm.state == VZVirtualMachine.State.running || vm.state == VZVirtualMachine.State.starting) {
            sleep(1);
        }
    } catch VMError.runtimeError(let errorMessage) {
        fatalError("vm error: \(errorMessage)");
    } catch (let errorMessage) {
        fatalError("error: \(errorMessage)");
    }
}

run();
