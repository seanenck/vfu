import Virtualization
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    @IBOutlet var window: NSWindow!
    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    private var virtualMachine: VZVirtualMachine!


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false

        openPanel.begin { (result) -> Void in
            if result == .OK {
                let args = Arguments(verbose: false, verify: false, config: openPanel.url!.path, graphical: true)
                DispatchQueue.main.async {
                    let config = VM().createConfiguration(args: args)
                    if (config == nil) {
                        return
                    }
                    let vm = VZVirtualMachine(configuration: config!)
                    self.virtualMachine = vm
                    self.virtualMachineView.virtualMachine = self.virtualMachine
                    self.virtualMachine.delegate = self
                    self.virtualMachine.start(completionHandler: { (result) in
                        switch result {
                        case let .failure(error):
                            fatalError("failed to start with error: \(error)")
                        default:
                            print("started.")
                        }
                    })
                }
            } else {
                fatalError("config file not selected")
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

