import Foundation

let configOption = "--config"
let helpOption = "--help"
let verifyOption = "--verify"
let verboseOption = "--verbose"
let quietOption = "--quiet"

struct Arguments {

    static let pathSep = "/"

    var verbose: Bool
    var quiet: Bool
    var verify: Bool
    var config: String
    var graphical: Bool
    var pwd: String?

    func readJSON() -> Configuration {
        do {
            if (self.config == "") {
                fatalError("no JSON configuration file given")
            }
            let text: String
            if (self.config == "-") {
                var lines = Array<String>()
                while let line = readLine() {
                    lines.append(line)
                }
                text = lines.joined(separator: "\n")
            } else {
                text = try String(contentsOfFile: self.config)
            }
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
    func log(level: LogLevel, message: String) {
        if (self.quiet) {
            return
        }
        if (level == LogLevel.Debug && !self.verbose) {
            return
        }
        print("[\(level)] \(message)")
    }
    mutating func setDirectory() {
        let parts = self.config.split(separator: Arguments.pathSep.first!)
        let pwd = parts[0...parts.count-2].joined(separator: Arguments.pathSep)
        self.pwd = Arguments.pathSep + pwd + Arguments.pathSep
    }
}

private func flags() -> Array<String> {
    return [configOption, verifyOption, helpOption, verboseOption, quietOption]
}

func parseArguments() -> Arguments? {
    var jsonConfig = ""
    var verifyMode = false
    var isVerbose = false
    var isQuiet = false
    let arguments = CommandLine.arguments.count - 1
    var matched = 0
    for flag in flags() {
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
                    case quietOption:
                        isQuiet = true
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
    if (isVerbose && isQuiet) {
        usage(message: "can not specify verbose and quiet together")
    }
    return Arguments(verbose: isVerbose, quiet: isQuiet, verify: verifyMode, config: jsonConfig, graphical: false)
}

private func usage(message: String) {
    print("vfu:")
    for flag in flags() {
        var indent = ""
        var extra = ""
        switch (flag) {
            case configOption:
                extra = "<configuration file> ('-' for stdin)"
            case verifyOption:
                extra = "verify the configuration only"
                indent = "  "
            case helpOption:
                extra = "display this help text"
            case verboseOption:
                extra = "include verbose log output"
            case quietOption:
                extra = "disable all log output"
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
    if (message != "") {
        fatalError(message)
    }
}
