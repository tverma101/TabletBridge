import Foundation
import AppKit
import Darwin

if CaptureSourceBenchmark.runIfRequested(arguments: CommandLine.arguments) {
    exit(0)
}

print("🚀 Tablet Bridge starting...")

let headlessLaunch = CommandLine.arguments.contains("--headless")
    || ProcessInfo.processInfo.environment["SIDESCREEN_HEADLESS"] == "1"

// Entry point
let app = NSApplication.shared

// Setup main menu for keyboard shortcuts (Command+Q, etc.)
let mainMenu = NSMenu()

// App menu
let appMenu = NSMenu()
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
appMenu.addItem(NSMenuItem(title: "About Tablet Bridge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(NSMenuItem(title: "Quit Tablet Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
mainMenu.addItem(appMenuItem)

// Edit menu (for standard text editing shortcuts)
let editMenu = NSMenu(title: "Edit")
let editMenuItem = NSMenuItem()
editMenuItem.submenu = editMenu
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
mainMenu.addItem(editMenuItem)

app.mainMenu = mainMenu

let delegate = AppDelegate(headlessLaunch: headlessLaunch)

// Normal Finder/DMG launches remain regular foreground apps. Diagnostic
// launches are accessory-only and never present/activate Settings.
app.setActivationPolicy(headlessLaunch ? .accessory : .regular)

app.delegate = delegate
app.run()
