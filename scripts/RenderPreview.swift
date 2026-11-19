import AppKit
import SwiftUI

// Renders the real view to a bitmap with a synthetic queue. Never captures the desktop.
@main
@MainActor
struct RenderPreview {
    static func main() throws {
        let target = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let state = BatchState()
        let fixture = URL(fileURLWithPath: "/Example/Studio Samples", isDirectory: true)
        state.inputs = ["Amber Bottle.tiff", "Packaging Detail.png", "Portrait Reference.heic", "Shadows.png"]
            .map { fixture.appendingPathComponent($0) }
        state.namingExpanded = true
        state.naming = ExportNaming(prefix: "studio_", suffix: "-2000w")
        let defaults = UserDefaults(suiteName: "io.twopointoh.pixel-crouton.docs-preview")!
        defaults.set("/Example/Web Exports", forKey: "exportPath")
        defer { defaults.removePersistentDomain(forName: "io.twopointoh.pixel-crouton.docs-preview") }
        let appearance: NSAppearance.Name = CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua
        let colorScheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let size = CGSize(width: 860, height: 720)
        let view = NSHostingView(rootView: BatchView(state: state).defaultAppStorage(defaults)
            .environment(\.colorScheme, colorScheme)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = window.contentRect(forFrameRect: window.frame).offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: target)
    }
}
