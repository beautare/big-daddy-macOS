import AppKit

@MainActor
func run() async {
    print("BigDaddy: main.swift execution started")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    print("BigDaddy: starting app.run()")
    app.run()
}

await run()
