import Virtualization
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {

    @IBOutlet var window: NSWindow!
    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!

    private var virtualMachine: VZVirtualMachine!
    private var isStarted: Bool!

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        runApp(isInit: true)
    }
    
    func isRunning() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3), execute: {
            if (self.virtualMachine != nil) {
                if (self.virtualMachine?.state == VZVirtualMachine.State.stopped){
                    print("machine stopped.");
                    exit(EXIT_SUCCESS);
                }
            }
            self.isRunning();
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
                var args = Arguments(verbose: false, verify: false, config: openPanel.url!.path, graphical: true)
                args.setDirectory()
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
                            print("machine started.")
                        }
                    })
                }
                self.isRunning()
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
