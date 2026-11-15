import AppKit

MainActor.assumeIsolated {
    if CommandLine.arguments.contains("--dump") {
        Dump.run()
    } else if let i = CommandLine.arguments.firstIndex(of: "--backlight-always-on") {
        BacklightAlwaysOnCommand.run(CommandLine.arguments.dropFirst(i + 1).first != "off")
    } else if CommandLine.arguments.contains("--fake-pc") {
        FakePC.run()
    } else if CommandLine.arguments.contains("--write-test") {
        WriteTest.run()
    } else {
        MXControlApp.main()
    }
}
