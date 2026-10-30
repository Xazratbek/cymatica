import AppKit

let options = LaunchOptions(arguments: CommandLine.arguments)
if options.isHeadless {
    exit(Headless.run(options))
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
