import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Forward plugin registration to every sub-window created via
    // desktop_multi_window (e.g. the desktop pet window). Without
    // this, plugins that depend on MethodChannels (e.g. window_manager)
    // wouldn't be available inside the pet window's Flutter
    // engine. See:
    // https://pub.dev/packages/desktop_multi_window#macos
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
      controller.backgroundColor = NSColor.clear
      controller.view.wantsLayer = true
      controller.view.layer?.backgroundColor = NSColor.clear.cgColor
      DispatchQueue.main.async {
        controller.view.window?.isOpaque = false
        controller.view.window?.backgroundColor = NSColor.clear
        controller.view.window?.hasShadow = false
      }
    }

    super.awakeFromNib()
  }
}
