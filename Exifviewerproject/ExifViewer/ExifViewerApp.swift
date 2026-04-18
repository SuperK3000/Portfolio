import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct ExifViewerApp: App {
    @StateObject private var model = ImageModel()

    var body: some Scene {
        Window("ExifViewer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            // App menu — replace the standard Settings item so it opens our sheet
            // instead of a separate Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .exifViewerOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFiles(replace: false) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open & Replace…") { openFiles(replace: true) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Divider()
                Button("Save") {
                    NotificationCenter.default.post(name: .exifViewerRequestSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.currentPhoto?.isDirty != true)
                Button("Save As…") {
                    NotificationCenter.default.post(name: .exifViewerRequestSaveAs, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.currentPhoto == nil)
                Divider()
                Button("Clear All") {
                    // ContentView decides whether to confirm (>5 photos) or clear immediately.
                    NotificationCenter.default.post(name: .exifViewerRequestClearAll, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.photos.isEmpty)
            }
            // Navigation menu under View
            CommandMenu("Navigate") {
                Button("Previous Photo") { model.selectPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.photos.isEmpty)
                Button("Next Photo") { model.selectNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.photos.isEmpty)
                Divider()
                Button("First Photo") { model.selectFirst() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(model.photos.isEmpty)
                Button("Last Photo") { model.selectLast() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(model.photos.isEmpty)
            }
        }
    }

    private func openFiles(replace: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true       // accept folders too
        panel.canChooseFiles = true
        panel.message = replace
            ? "Select JPGs or folders — replaces the current set."
            : "Select JPGs or folders — appended to the current set."
        if let jpg = UTType("public.jpeg") {
            panel.allowedContentTypes = [jpg, .folder]
        }
        if panel.runModal() == .OK {
            let urls = panel.urls
            if replace { model.replace(urls: urls) } else { model.append(urls: urls) }
        }
    }
}
