func run() {
    let vfu = VM()
    let args = vfu.parseArguments()
    if (args == nil) {
        return
    }
    let useArgs = args!
    let config = vfu.createConfiguration(args: useArgs)
    if (config == nil) {
        return
    }
    vfu.runCLI(config: config!, args: useArgs)
}

run()
