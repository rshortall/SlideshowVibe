import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        showFolderPicker()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Photo Folder"
        panel.message = "Select a folder containing your photos"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let response = panel.runModal()
        guard response == .OK, let folderURL = panel.url else {
            NSApp.terminate(nil)
            return
        }

        launchSlideshowWindow(folderURL: folderURL)
    }

    private func launchSlideshowWindow(folderURL: URL) {
        let minSize = NSSize(width: 1280, height: 800)

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "SlideshowVibe"
        window.minSize = minSize
        window.center()
        window.isReleasedWhenClosed = false

        let vc = SlideshowViewController(folderURL: folderURL)
        window.contentViewController = vc

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
