import Virtualization
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    @IBOutlet var window: NSWindow!
    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    private var virtualMachine: VZVirtualMachine!
    private var isStarted: Bool!
    private var sleep = 3

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        runApp(isInit: true)
    }
    
    func isRunning(config: VMConfiguration, since: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sleep), execute: {
            var next = since + self.sleep
            if (self.virtualMachine != nil) {
                if (self.virtualMachine?.state == VZVirtualMachine.State.stopped){
                    print("machine stopped.");
                    exit(EXIT_SUCCESS);
                }
                if (handleClockSync(since: next, vm: self.virtualMachine, config: config) { (level, msg) in
                    print("\(level) \(msg)")
                }) {
                    next = 0
                }
            }
            self.isRunning(config: config, since: next);
        })
    }
    
    func runApp(isInit: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        self.window.title = "vfu-gui"
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        
        openPanel.begin { (result) -> Void in
            if result == .OK {
                var args = Arguments(verbose: false, quiet: false, verify: false, config: openPanel.url!.path, graphical: true)
                args.setDirectory()
                let config = createConfiguration(args: args)
                if (config == nil) {
                    return
                }
                let vm = VZVirtualMachine(configuration: config!.vmConfig)
                DispatchQueue.main.async {
                    self.virtualMachine = vm
                    self.virtualMachineView.virtualMachine = self.virtualMachine
                    self.virtualMachine.delegate = self
                    self.virtualMachine.start(completionHandler: { (result) in
                        switch result {
                        case let .failure(error):
                            fatalError("failed to start with error: \(error)")
                        default:
                            print("machine started.")
                        }
                    })
                }
                self.isRunning(config: config!, since: 0)
            } else {
                print("exiting.")
                exit(EXIT_SUCCESS)
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
