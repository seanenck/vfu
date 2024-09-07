func run() {
    let args = parseArguments()
    if (args == nil) {
        return
    }
    let useArgs = args!
    let config = createConfiguration(args: useArgs)
    if (config == nil) {
        return
    }
    runCLI(config: config!, args: useArgs)
}

run()
