import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class ImageModel: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published var selectedIndex: Int? = nil

    private let thumbQueue = DispatchQueue(label: "exifviewer.thumbnails", qos: .userInitiated, attributes: .concurrent)

    var currentPhoto: Photo? {
        guard let i = selectedIndex, photos.indices.contains(i) else { return nil }
        return photos[i]
    }

    /// Append URLs (folders are walked, dupes against existing set are skipped).
    func append(urls: [URL]) {
        let jpgs = JPGFinder.collectJPGs(from: urls)
        let existing = Set(photos.map { $0.url.standardizedFileURL.path })
        let fresh = jpgs.filter { !existing.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        let wasEmpty = photos.isEmpty
        let newPhotos = fresh.map { Photo(url: $0) }
        photos.append(contentsOf: newPhotos)
        if wasEmpty { selectedIndex = 0 }
        for p in newPhotos { generateThumbnail(for: p) }
    }

    /// Replace the entire set with the given URLs.
    func replace(urls: [URL]) {
        let jpgs = JPGFinder.collectJPGs(from: urls)
        photos = jpgs.map { Photo(url: $0) }
        selectedIndex = photos.isEmpty ? nil : 0
        for p in photos { generateThumbnail(for: p) }
    }

    func clear() {
        photos = []
        selectedIndex = nil
    }

    /// Remove a single photo. Adjusts selection: prefers the next photo,
    /// falls back to the previous one if the removed photo was last.
    func remove(id: UUID) {
        guard let removeAt = photos.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = (selectedIndex == removeAt)
        let oldSelected = selectedIndex
        photos.remove(at: removeAt)

        if photos.isEmpty {
            selectedIndex = nil
        } else if wasSelected {
            // Prefer the photo that took the removed slot; if we removed the last, step back.
            selectedIndex = min(removeAt, photos.count - 1)
        } else if let s = oldSelected, s > removeAt {
            // Selection sat after the removed item — shift it left to keep pointing at the same photo.
            selectedIndex = s - 1
        }
    }

    func select(index: Int) {
        guard photos.indices.contains(index) else { return }
        selectedIndex = index
    }

    func selectNext()     { if let i = selectedIndex, i + 1 < photos.count { selectedIndex = i + 1 } }
    func selectPrevious() { if let i = selectedIndex, i > 0 { selectedIndex = i - 1 } }
    func selectFirst()    { if !photos.isEmpty { selectedIndex = 0 } }
    func selectLast()     { if !photos.isEmpty { selectedIndex = photos.count - 1 } }

    /// Ensures the current photo's full image + EXIF + editable buffer are loaded.
    func ensureLoaded(_ photo: Photo) {
        if photo.fullImage == nil {
            photo.fullImage = NSImage(contentsOf: photo.url)
        }
        if photo.metadata == nil {
            photo.metadata = ExifMetadata.extract(from: photo.url)
        }
        if photo.edits == nil {
            let e = EditableMetadata.extract(from: photo.url)
            photo.originalEdits = e
            photo.edits = e
            photo.wasEditedByApp = Photo.checkEditedByApp(url: photo.url)
        }
    }

    /// Re-reads metadata from disk after a successful save and updates the dirty snapshot.
    func reloadAfterSave(_ photo: Photo) {
        photo.metadata = ExifMetadata.extract(from: photo.url)
        let e = EditableMetadata.extract(from: photo.url)
        photo.edits = e
        photo.originalEdits = e
        photo.pendingName = nil
        photo.wasEditedByApp = Photo.checkEditedByApp(url: photo.url)
        // Drop the cached full image so next display picks up the new file.
        photo.fullImage = nil
        // Regenerate the thumbnail asynchronously.
        photo.thumbnail = nil
        generateThumbnail(for: photo)
        // Notify subscribers (Photo's @Published edits already nudges, but this also
        // covers metadata which isn't @Published).
        objectWillChange.send()
    }

    private func generateThumbnail(for photo: Photo) {
        if photo.thumbnail != nil { return }
        let url = photo.url
        thumbQueue.async { [weak photo] in
            let img = Photo.makeThumbnail(url: url, maxPixelSize: 200)
            DispatchQueue.main.async {
                photo?.thumbnail = img
            }
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject var model: ImageModel
    @FocusState private var focused: Bool
    @State private var showClearConfirm: Bool = false
    @State private var showSettings: Bool = false
    @State private var showOverwriteConfirm: Bool = false
    @State private var saveError: IdentifiableString? = nil
    @State private var saveSuccess: IdentifiableString? = nil
    /// Captured at the moment the user clicks Save, so it survives any view re-renders
    /// that might reset `photo.pendingName` before the confirm dialog returns.
    @State private var pendingRenameForSave: String? = nil
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    imagePane
                        .frame(width: geo.size.width * 0.7)
                    Divider()
                    metadataPane
                        .frame(width: geo.size.width * 0.3)
                }
            }
            Divider()
            thumbnailStrip
                .frame(height: 110)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow)  { handleArrow(.left,  modifiers: NSEvent.modifierFlags) }
        .onKeyPress(.rightArrow) { handleArrow(.right, modifiers: NSEvent.modifierFlags) }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: model.selectedIndex) { _, _ in
            if let p = model.currentPhoto { model.ensureLoaded(p) }
        }
        .alert("Clear all \(model.photos.count) photos?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { model.clear() }
        } message: {
            Text("This removes every loaded photo. The files on disk are not affected.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .exifViewerRequestClearAll)) { _ in
            requestClearAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exifViewerOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .exifViewerRequestSave)) { _ in
            requestSaveInPlace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exifViewerRequestSaveAs)) { _ in
            runSaveAs()
        }
        .confirmationDialog(
            "Overwrite the original?",
            isPresented: $showOverwriteConfirm,
            titleVisibility: .visible
        ) {
            Button("Save and Back Up Original", role: .destructive) { runSaveInPlace() }
            Button("Cancel", role: .cancel) { pendingRenameForSave = nil }
        } message: {
            if let p = model.currentPhoto {
                let backup = MetadataWriter.backupPath(for: p.url)
                if let newName = pendingRenameForSave {
                    Text("\(p.displayName) will be renamed to \(newName) and overwritten. A copy of the current file will be saved to \(backup.lastPathComponent) in the same folder first.")
                } else {
                    Text("\(p.displayName) will be overwritten. A copy of the current file will be saved to \(backup.lastPathComponent) in the same folder first.")
                }
            } else {
                Text("A backup of the current file will be created first.")
            }
        }
        .alert(item: $saveError) { err in
            Alert(title: Text("Save failed"), message: Text(err.value), dismissButton: .default(Text("OK")))
        }
        .alert(item: $saveSuccess) { msg in
            Alert(title: Text("Saved"), message: Text(msg.value), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Save handlers

    func requestSaveInPlace() {
        guard let p = model.currentPhoto else { return }
        guard p.isDirty, let edits = p.edits else { return }
        let errs = validate(edits)
        if errs.any {
            saveError = IdentifiableString(value: firstError(errs))
            return
        }
        // Snapshot the rename now — view re-renders during the confirm dialog can
        // otherwise wipe `photo.pendingName` before runSaveInPlace gets to read it.
        pendingRenameForSave = p.pendingName
        showOverwriteConfirm = true
    }

    private func runSaveInPlace() {
        guard let p = model.currentPhoto, let edits = p.edits else {
            pendingRenameForSave = nil
            return
        }
        let renameTo = pendingRenameForSave
        pendingRenameForSave = nil

        // Apply the captured rename first, so the backup + overwrite use the new name.
        if let pending = renameTo {
            do { try p.rename(to: pending) }
            catch {
                saveError = IdentifiableString(value: error.localizedDescription)
                return
            }
        }
        do {
            let backup = try MetadataWriter.saveInPlace(source: p.url, edits: edits)
            model.reloadAfterSave(p)
            let renamedNote = (renameTo != nil) ? " Renamed to \(p.displayName)." : ""
            saveSuccess = IdentifiableString(value: "Original backed up to \(backup.lastPathComponent).\(renamedNote)")
        } catch {
            saveError = IdentifiableString(value: error.localizedDescription)
        }
    }

    func runSaveAs() {
        guard let p = model.currentPhoto, let edits = p.edits else { return }
        let errs = validate(edits)
        if errs.any {
            saveError = IdentifiableString(value: firstError(errs))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        // Prefer the pending rename if the user typed one, otherwise <stem>-edited.jpg
        let defaultName: String = {
            if let pending = p.pendingName, !pending.isEmpty { return pending }
            let stem = p.url.deletingPathExtension().lastPathComponent
            let ext  = p.url.pathExtension.isEmpty ? "jpg" : p.url.pathExtension
            return "\(stem)-edited.\(ext)"
        }()
        panel.nameFieldStringValue = defaultName
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try MetadataWriter.saveAs(source: p.url, edits: edits, destination: dest)
            saveSuccess = IdentifiableString(value: "Saved to \(dest.lastPathComponent).")
        } catch {
            saveError = IdentifiableString(value: error.localizedDescription)
        }
    }

    func discardChanges(for p: Photo) {
        if let o = p.originalEdits { p.edits = o }
    }

    private func validate(_ edits: EditableMetadata) -> EditableMetadata.Errors {
        let latTxt = edits.latitude.map { String($0) } ?? ""
        let lonTxt = edits.longitude.map { String($0) } ?? ""
        return EditableMetadata.validate(
            latText: latTxt, lonText: lonTxt,
            artist: edits.artist, copyright: edits.copyright, description: edits.imageDescription
        )
    }

    private func firstError(_ e: EditableMetadata.Errors) -> String {
        return e.lat ?? e.lon ?? e.artist ?? e.copyright ?? e.description ?? "Invalid input."
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }

    /// Public entry point for menu / button. Confirms only when > 5 photos.
    func requestClearAll() {
        guard !model.photos.isEmpty else { return }
        if model.photos.count > 5 {
            showClearConfirm = true
        } else {
            model.clear()
        }
    }

    private var windowTitle: String {
        if let i = model.selectedIndex, !model.photos.isEmpty {
            return "ExifViewer — \(i + 1) of \(model.photos.count)"
        }
        return "ExifViewer"
    }

    // MARK: Panes

    private var imagePane: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if let p = model.currentPhoto, let img = p.fullImage ?? NSImage(contentsOf: p.url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                placeholder
            }
        }
    }

    private var metadataPane: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
            if let p = model.currentPhoto {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        MetadataHeader(photo: p)
                            .id(p.id)
                        Divider()
                        let fields = p.metadata?.fields ?? []
                        if fields.isEmpty {
                            Text("No EXIF metadata found.")
                                .appFont(.body)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(fields) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label).appFont(.caption).foregroundStyle(.secondary)
                                    Text(field.value).appFont(.body).textSelection(.enabled)
                                }
                            }
                        }

                        Divider().padding(.vertical, 4)

                        MetadataEditor(
                            photo: p,
                            onSave:    { requestSaveInPlace() },
                            onSaveAs:  { runSaveAs() },
                            onDiscard: { discardChanges(for: p) }
                        )
                        .id(p.id)  // reset editor's local state when photo changes
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Drag a JPG here or press ⌘O")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
    }

    private var thumbnailStrip: some View {
        ZStack(alignment: .topTrailing) {
            Color(NSColor.underPageBackgroundColor)
            if model.photos.isEmpty {
                Text("No photos loaded")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // Trailing padding leaves room for the Clear All button.
                        HStack(spacing: 8) {
                            ForEach(Array(model.photos.enumerated()), id: \.element.id) { (idx, photo) in
                                ThumbnailCell(
                                    photo: photo,
                                    isSelected: idx == model.selectedIndex,
                                    onSelect: { model.select(index: idx) },
                                    onRemove: { model.remove(id: photo.id) }
                                )
                                .id(photo.id)
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 96)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: model.selectedIndex) { _, newIdx in
                        if let i = newIdx, model.photos.indices.contains(i) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(model.photos[i].id, anchor: .center)
                            }
                        }
                    }
                }

                // Clear All — pinned top-right of the strip, above the scroll content.
                Button {
                    requestClearAll()
                } label: {
                    Label("Clear All", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                        .appFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove all loaded photos (⌘⌫)")
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            // SF Symbol — kept at fixed pixel size since it's iconography, not text.
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drag a JPG here or press ⌘O")
                .appFont(.title)
                .foregroundStyle(.secondary)
            Text("Drop multiple files or a folder to load many at once.\nHold ⌥ Option while dropping to replace.")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Input

    private enum Arrow { case left, right }
    private func handleArrow(_ dir: Arrow, modifiers: NSEvent.ModifierFlags) -> KeyPress.Result {
        guard !model.photos.isEmpty else { return .ignored }
        let cmd = modifiers.contains(.command)
        switch dir {
        case .left:  cmd ? model.selectFirst() : model.selectPrevious()
        case .right: cmd ? model.selectLast()  : model.selectNext()
        }
        return .handled
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let replace = NSEvent.modifierFlags.contains(.option)
        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); collected.append(url); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [model] in
            guard !collected.isEmpty else { return }
            if replace { model.replace(urls: collected) }
            else        { model.append(urls: collected) }
        }
        return true
    }
}

// MARK: - Thumbnail cell

private struct ThumbnailCell: View {
    @ObservedObject var photo: Photo
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Image / placeholder, tappable to select.
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.controlBackgroundColor))
                if let t = photo.thumbnail {
                    Image(nsImage: t)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 92, height: 92)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.25),
                                  lineWidth: isSelected ? 3 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { onSelect() }

            // Hover-revealed remove button.
            if isHovered {
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.65))
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove this photo")
                .padding(4)
                .transition(.opacity)
            }
        }
        .frame(width: 92, height: 92)
        .help(photo.displayName)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }
}

extension Notification.Name {
    static let exifViewerRequestClearAll = Notification.Name("ExifViewerRequestClearAll")
    static let exifViewerOpenSettings    = Notification.Name("ExifViewerOpenSettings")
    static let exifViewerRequestSave     = Notification.Name("ExifViewerRequestSave")
    static let exifViewerRequestSaveAs   = Notification.Name("ExifViewerRequestSaveAs")
}

struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
}

// MARK: - Filename header (editable name + reveal in Finder)

private struct MetadataHeader: View {
    @ObservedObject var photo: Photo
    @State private var nameDraft: String = ""
    @State private var renameError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Filename", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .appFont(.headline)
                    .onSubmit { commitRename() }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([photo.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("Reveal in Finder")
            }
            HStack(spacing: 8) {
                if photo.isDirty {
                    Text("• Modified").appFont(.caption).foregroundStyle(.orange)
                }
                if photo.wasEditedByApp {
                    Label("Edited in ExifViewer", systemImage: "checkmark.seal")
                        .labelStyle(.titleAndIcon)
                        .appFont(.caption)
                        .foregroundStyle(.blue)
                        .help("A previous save by ExifViewer stamped this file.")
                }
            }
            if let err = renameError {
                Text(err).appFont(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { syncFromPhoto() }
        .onChange(of: photo.url) { _, _ in syncFromPhoto() }
        .onChange(of: nameDraft) { _, new in
            // Keep photo.pendingName in sync so Save can apply it and the dirty flag flips.
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == photo.displayName {
                photo.pendingName = nil
            } else {
                photo.pendingName = trimmed
            }
            renameError = nil
        }
    }

    private func syncFromPhoto() {
        nameDraft = photo.displayName
        photo.pendingName = nil
        renameError = nil
    }

    private func commitRename() {
        let target = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if target == photo.displayName {
            photo.pendingName = nil
            renameError = nil
            return
        }
        do {
            try photo.rename(to: target)
            photo.pendingName = nil
            renameError = nil
        } catch let e as Photo.RenameError {
            renameError = e.errorDescription
            nameDraft = photo.displayName
            photo.pendingName = nil
        } catch {
            renameError = error.localizedDescription
            nameDraft = photo.displayName
            photo.pendingName = nil
        }
    }
}

// MARK: - Editable metadata editor

private struct MetadataEditor: View {
    @ObservedObject var photo: Photo
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onDiscard: () -> Void

    // Local string buffers so users can type "-", "12.", etc. mid-entry.
    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var hasDate: Bool = false
    @State private var date: Date = Date()
    @State private var didInit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Metadata").appFont(.headline)

            // Date taken
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Set date taken", isOn: $hasDate)
                    .appFont(.caption)
                if hasDate {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
            }

            // GPS
            VStack(alignment: .leading, spacing: 4) {
                Text("GPS Coordinates").appFont(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Latitude", text: $latText)
                        .textFieldStyle(.roundedBorder)
                        .appFont(.body)
                    TextField("Longitude", text: $lonText)
                        .textFieldStyle(.roundedBorder)
                        .appFont(.body)
                }
                if let msg = gpsError {
                    Text(msg).appFont(.caption).foregroundStyle(.red)
                } else {
                    Text("Decimal degrees. Negative = S / W. Leave both blank to clear.")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Artist
            VStack(alignment: .leading, spacing: 4) {
                Text("Artist").appFont(.caption).foregroundStyle(.secondary)
                TextField("", text: stringBinding(\.artist))
                    .textFieldStyle(.roundedBorder)
                    .appFont(.body)
            }

            // Copyright
            VStack(alignment: .leading, spacing: 4) {
                Text("Copyright").appFont(.caption).foregroundStyle(.secondary)
                TextField("", text: stringBinding(\.copyright))
                    .textFieldStyle(.roundedBorder)
                    .appFont(.body)
            }

            // Description
            VStack(alignment: .leading, spacing: 4) {
                Text("Description").appFont(.caption).foregroundStyle(.secondary)
                TextEditor(text: stringBinding(\.imageDescription))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.gray.opacity(0.3)))
            }

            // Actions
            HStack(spacing: 8) {
                Button("Save") { onSave() }
                    .disabled(!photo.isDirty || hasValidationErrors)
                    .help("Overwrite the original file. A backup is created first. (⌘S)")
                Button("Save As…") { onSaveAs() }
                    .disabled(hasValidationErrors)
                    .help("Write to a new file. (⌘⇧S)")
                Spacer()
                Button("Discard") { onDiscard() }
                    .disabled(!photo.isDirty)
            }
            .appFont(.body)
            .padding(.top, 4)
        }
        .onAppear { initializeIfNeeded() }
        .onChange(of: latText) { _, new in writeLat(new) }
        .onChange(of: lonText) { _, new in writeLon(new) }
        .onChange(of: hasDate) { _, on in
            var e = photo.edits ?? EditableMetadata()
            e.dateTaken = on ? date : nil
            photo.edits = e
        }
        .onChange(of: date) { _, new in
            guard hasDate else { return }
            var e = photo.edits ?? EditableMetadata()
            e.dateTaken = new
            photo.edits = e
        }
    }

    // MARK: Bindings + helpers

    private func stringBinding(_ kp: WritableKeyPath<EditableMetadata, String>) -> Binding<String> {
        Binding(
            get: { photo.edits?[keyPath: kp] ?? "" },
            set: { new in
                var e = photo.edits ?? EditableMetadata()
                e[keyPath: kp] = new
                photo.edits = e
            }
        )
    }

    private func initializeIfNeeded() {
        guard !didInit else { return }
        didInit = true
        if let e = photo.edits {
            latText = e.latitude.map { String($0) } ?? ""
            lonText = e.longitude.map { String($0) } ?? ""
            if let d = e.dateTaken {
                hasDate = true
                date = d
            } else {
                hasDate = false
            }
        }
    }

    private func writeLat(_ s: String) {
        var e = photo.edits ?? EditableMetadata()
        let t = s.trimmingCharacters(in: .whitespaces)
        e.latitude = t.isEmpty ? nil : Double(t)
        photo.edits = e
    }

    private func writeLon(_ s: String) {
        var e = photo.edits ?? EditableMetadata()
        let t = s.trimmingCharacters(in: .whitespaces)
        e.longitude = t.isEmpty ? nil : Double(t)
        photo.edits = e
    }

    private var currentErrors: EditableMetadata.Errors {
        EditableMetadata.validate(
            latText: latText, lonText: lonText,
            artist: photo.edits?.artist ?? "",
            copyright: photo.edits?.copyright ?? "",
            description: photo.edits?.imageDescription ?? ""
        )
    }

    private var hasValidationErrors: Bool { currentErrors.any }

    private var gpsError: String? { currentErrors.lat ?? currentErrors.lon }
}

// MARK: - App font system
//
// A single point of truth for typography. Each view applies `.appFont(.role)` and the
// modifier reads @AppStorage directly, so changes in Settings update everywhere immediately.

enum AppFontRole {
    case caption, body, callout, headline, title

    func size(base: Double) -> CGFloat {
        switch self {
        case .caption:  return max(8, CGFloat(base) - 2)
        case .body:     return CGFloat(base)
        case .callout:  return CGFloat(base)
        case .headline: return CGFloat(base) + 1
        case .title:    return CGFloat(base) + 4
        }
    }
}

struct AppFontModifier: ViewModifier {
    @AppStorage("selectedFontFamily") private var family: String = "System"
    @AppStorage("fontSize")           private var size: Double = 13.0
    let role: AppFontRole

    func body(content: Content) -> some View {
        let s = role.size(base: size)
        let weight: Font.Weight = (role == .headline) ? .semibold : .regular
        let font: Font = (family == "System")
            ? .system(size: s, weight: weight)
            : .custom(family, size: s)
        return content.font(font)
    }
}

extension View {
    func appFont(_ role: AppFontRole = .body) -> some View {
        modifier(AppFontModifier(role: role))
    }
}

// MARK: - Font discovery
//
// Returns "System" plus all monospace and sans-serif font families installed on macOS,
// using NSFontDescriptor symbolic traits and the family-class bits.

enum FontHelper {
    static func availableFamilies() -> [String] {
        let mgr = NSFontManager.shared
        let filtered = mgr.availableFontFamilies.filter(isMonoOrSans)
        return ["System"] + filtered.sorted()
    }

    private static func isMonoOrSans(_ family: String) -> Bool {
        let mgr = NSFontManager.shared
        guard let members = mgr.availableMembers(ofFontFamily: family),
              let psName = members.first?.first as? String,
              let font = NSFont(name: psName, size: 12) else { return false }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.monoSpace) { return true }
        // NSFontFamilyClass lives in the high nibble of the symbolic-traits raw value.
        // sansSerif == 8.
        let classRaw = (traits.rawValue & 0xF000_0000) >> 28
        return classRaw == 8
    }
}

// MARK: - Settings sheet

struct SettingsView: View {
    @AppStorage("selectedFontFamily") private var fontFamily: String = "System"
    @AppStorage("fontSize")           private var fontSize: Double = 13.0
    @AppStorage("appearanceMode")     private var appearanceMode: String = "system"
    @Environment(\.dismiss) private var dismiss

    private let families: [String] = FontHelper.availableFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // ── Font ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                Text("Font").font(.headline)

                HStack {
                    Text("Family")
                        .frame(width: 60, alignment: .leading)
                    Picker("", selection: $fontFamily) {
                        ForEach(families, id: \.self) { fam in
                            Text(fam).tag(fam)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Size")
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $fontSize, in: 10...20, step: 1)
                        Text("\(Int(fontSize))pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Aperture: f/2.8 — 1/250s — ISO 400")
                        .font(previewFont)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
                        )
                }
            }

            Divider()

            // ── Appearance ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.headline)
                Picker("", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 350)
    }

    private var previewFont: Font {
        if fontFamily == "System" {
            return .system(size: CGFloat(fontSize))
        }
        return .custom(fontFamily, size: CGFloat(fontSize))
    }
}
