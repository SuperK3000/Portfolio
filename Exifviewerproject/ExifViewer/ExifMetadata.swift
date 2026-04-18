import Foundation
import ImageIO
import AppKit

// MARK: - EXIF

struct ExifField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct ExifMetadata {
    var fields: [ExifField] = []

    static func extract(from url: URL) -> ExifMetadata {
        var meta = ExifMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return meta
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        func add(_ label: String, _ value: String?) {
            if let v = value, !v.isEmpty { meta.fields.append(ExifField(label: label, value: v)) }
        }

        add("Camera Make", tiff[kCGImagePropertyTIFFMake] as? String)
        add("Camera Model", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)

        if let fnum = exif[kCGImagePropertyExifFNumber] as? Double {
            add("Aperture", String(format: "f/%.1f", fnum))
        }

        if let exp = exif[kCGImagePropertyExifExposureTime] as? Double {
            let formatted: String
            if exp >= 1 {
                formatted = String(format: "%.1fs", exp)
            } else {
                let denom = Int((1.0 / exp).rounded())
                formatted = "1/\(denom)s"
            }
            add("Shutter Speed", formatted)
        }

        if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let iso = isoArr.first {
            add("ISO", "\(iso)")
        }

        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            add("Focal Length", String(format: "%.0fmm", fl))
        }

        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            add("Exposure Compensation", String(format: "%+.1f EV", bias))
        }

        if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let inFmt = DateFormatter()
            inFmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = inFmt.date(from: dateStr) {
                let outFmt = DateFormatter()
                outFmt.dateStyle = .medium
                outFmt.timeStyle = .medium
                add("Date Taken", outFmt.string(from: date))
            } else {
                add("Date Taken", dateStr)
            }
        }

        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        if let w, let h {
            add("Dimensions", "\(w) × \(h)")
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            add("File Size", fmt.string(fromByteCount: size))
        }

        return meta
    }
}

// MARK: - Editable metadata

/// Mutable subset of EXIF/TIFF/GPS fields we let the user edit.
struct EditableMetadata: Equatable {
    var dateTaken: Date?
    var latitude: Double?
    var longitude: Double?
    var artist: String = ""
    var copyright: String = ""
    var imageDescription: String = ""

    /// Reads the current values from a JPG. Missing fields become nil/empty.
    static func extract(from url: URL) -> EditableMetadata {
        var out = EditableMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return out
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps  = props[kCGImagePropertyGPSDictionary]  as? [CFString: Any] ?? [:]

        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            out.dateTaken = f.date(from: s)
        }
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
            let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            out.latitude = (ref == "S") ? -lat : lat
        }
        if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            out.longitude = (ref == "W") ? -lon : lon
        }
        out.artist           = (tiff[kCGImagePropertyTIFFArtist]           as? String) ?? ""
        out.copyright        = (tiff[kCGImagePropertyTIFFCopyright]        as? String) ?? ""
        out.imageDescription = (tiff[kCGImagePropertyTIFFImageDescription] as? String) ?? ""
        return out
    }

    // MARK: Validation

    struct Errors {
        var lat: String?
        var lon: String?
        var artist: String?
        var copyright: String?
        var description: String?
        var any: Bool { lat != nil || lon != nil || artist != nil || copyright != nil || description != nil }
    }

    /// Validates the edits. `latText`/`lonText` are the raw text inputs, since the
    /// editor uses string buffers to allow in-progress entry like "-" or "12.".
    static func validate(latText: String, lonText: String, artist: String,
                         copyright: String, description: String) -> Errors {
        var e = Errors()
        let latTrim = latText.trimmingCharacters(in: .whitespaces)
        let lonTrim = lonText.trimmingCharacters(in: .whitespaces)

        // GPS: both empty (clears) or both present and in range.
        if latTrim.isEmpty != lonTrim.isEmpty {
            if latTrim.isEmpty { e.lat = "Required when longitude is set" }
            if lonTrim.isEmpty { e.lon = "Required when latitude is set" }
        } else if !latTrim.isEmpty {
            if let v = Double(latTrim) {
                if v < -90 || v > 90 { e.lat = "Must be between -90 and 90" }
            } else {
                e.lat = "Not a number"
            }
            if let v = Double(lonTrim) {
                if v < -180 || v > 180 { e.lon = "Must be between -180 and 180" }
            } else {
                e.lon = "Not a number"
            }
        }

        // String length caps. EXIF/TIFF fields are practically bounded; pick a
        // generous limit so users can't accidentally bloat headers.
        if artist.count      > 1000 { e.artist      = "Max 1000 characters" }
        if copyright.count   > 1000 { e.copyright   = "Max 1000 characters" }
        if description.count > 4000 { e.description = "Max 4000 characters" }

        return e
    }
}

// MARK: - Writer

enum MetadataWriteError: LocalizedError {
    case cantOpenSource
    case cantCreateDestination
    case finalizeFailed
    case backupFailed(underlying: Error)
    case writeFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .cantOpenSource:           return "Could not read the source image."
        case .cantCreateDestination:    return "Could not create the output file."
        case .finalizeFailed:           return "Failed to finalize the JPEG output."
        case .backupFailed(let e):      return "Backup failed: \(e.localizedDescription)"
        case .writeFailed(let e):       return "Write failed: \(e.localizedDescription)"
        }
    }
}

enum MetadataWriter {

    /// Picks a non-clobbering backup path: `name.original.jpg`, then `name.original-1.jpg`, etc.
    static func backupPath(for original: URL) -> URL {
        let dir  = original.deletingLastPathComponent()
        let stem = original.deletingPathExtension().lastPathComponent
        let ext  = original.pathExtension
        var candidate = dir.appendingPathComponent("\(stem).original.\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem).original-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// In-place save: backs up the original first, then atomically replaces it.
    /// Returns the path of the backup file that was created.
    @discardableResult
    static func saveInPlace(source: URL, edits: EditableMetadata) throws -> URL {
        let backup = backupPath(for: source)
        do {
            try FileManager.default.copyItem(at: source, to: backup)
        } catch {
            throw MetadataWriteError.backupFailed(underlying: error)
        }
        do {
            try writeMerged(source: source, edits: edits, destination: source)
        } catch {
            // Best-effort rollback of the (untouched) original from backup if the
            // atomic replace half-failed. We only delete the backup if the original
            // is intact; otherwise leave the backup alone for the user to recover.
            throw error
        }
        return backup
    }

    /// Save-As: writes to a new path. Overwrites the destination atomically if it exists.
    static func saveAs(source: URL, edits: EditableMetadata, destination: URL) throws {
        try writeMerged(source: source, edits: edits, destination: destination)
    }

    // MARK: Internal

    /// Merges `edits` into the source's existing properties and writes JPEG bytes
    /// to a temp file in the destination directory, then atomically swaps into place.
    private static func writeMerged(source: URL, edits: EditableMetadata, destination: URL) throws {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let uti = CGImageSourceGetType(src) else {
            throw MetadataWriteError.cantOpenSource
        }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        var tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        var gps  = (props[kCGImagePropertyGPSDictionary]  as? [CFString: Any]) ?? [:]

        // Date
        if let d = edits.dateTaken {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            let s = f.string(from: d)
            exif[kCGImagePropertyExifDateTimeOriginal]  = s
            exif[kCGImagePropertyExifDateTimeDigitized] = s
            tiff[kCGImagePropertyTIFFDateTime]          = s
        }

        // GPS — both set or both cleared.
        if let lat = edits.latitude, let lon = edits.longitude {
            gps[kCGImagePropertyGPSLatitude]     = abs(lat)
            gps[kCGImagePropertyGPSLatitudeRef]  = lat >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitude]    = abs(lon)
            gps[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
        } else if edits.latitude == nil && edits.longitude == nil {
            for k in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                      kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef] {
                gps.removeValue(forKey: k)
            }
        }

        // Artist / Copyright / Description (TIFF). Empty string = remove.
        func setOrRemove(_ key: CFString, _ value: String, in dict: inout [CFString: Any]) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { dict.removeValue(forKey: key) } else { dict[key] = trimmed }
        }
        setOrRemove(kCGImagePropertyTIFFArtist,           edits.artist,           in: &tiff)
        setOrRemove(kCGImagePropertyTIFFCopyright,        edits.copyright,        in: &tiff)
        setOrRemove(kCGImagePropertyTIFFImageDescription, edits.imageDescription, in: &tiff)

        // Mark this file as last-written by ExifViewer so future loads can detect it.
        tiff[kCGImagePropertyTIFFSoftware] = Photo.appSoftwareTag

        props[kCGImagePropertyExifDictionary] = exif
        props[kCGImagePropertyTIFFDictionary] = tiff
        if !gps.isEmpty {
            props[kCGImagePropertyGPSDictionary] = gps
        } else {
            props.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }

        // Write to a temp file in the destination's directory (same volume guarantees rename atomicity).
        let destDir = destination.deletingLastPathComponent()
        let tmp = destDir.appendingPathComponent(".exifviewer-tmp-\(UUID().uuidString).jpg")

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, uti, 1, nil) else {
            throw MetadataWriteError.cantCreateDestination
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tmp)
            throw MetadataWriteError.finalizeFailed
        }

        // Atomic swap: replaceItemAt if the destination exists, otherwise rename.
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw MetadataWriteError.writeFailed(underlying: error)
        }
    }
}

// MARK: - Photo

final class Photo: Identifiable, ObservableObject {
    let id = UUID()
    @Published var url: URL
    @Published var thumbnail: NSImage?
    @Published var metadata: ExifMetadata?
    var fullImage: NSImage?  // lazy-loaded on first display, cached thereafter

    enum RenameError: LocalizedError {
        case invalidName
        case alreadyExists
        case failed(Error)
        var errorDescription: String? {
            switch self {
            case .invalidName:      return "That name isn't allowed."
            case .alreadyExists:    return "A file with that name already exists in this folder."
            case .failed(let e):    return "Rename failed: \(e.localizedDescription)"
            }
        }
    }

    /// Renames the underlying file on disk and updates `url`. No-op if the name hasn't changed.
    func rename(to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              trimmed != ".", trimmed != ".."
        else { throw RenameError.invalidName }

        let newURL = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if newURL.standardizedFileURL == url.standardizedFileURL { return }
        if FileManager.default.fileExists(atPath: newURL.path) {
            throw RenameError.alreadyExists
        }
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            self.url = newURL
        } catch {
            throw RenameError.failed(error)
        }
    }

    /// Mutable buffer the editor binds to. Populated by `ImageModel.ensureLoaded`.
    @Published var edits: EditableMetadata?
    /// Snapshot of `edits` taken at load time (and after each successful save).
    /// Used to detect unsaved changes via `isDirty`.
    var originalEdits: EditableMetadata?

    /// Live draft bound to the filename TextField. Initialized to `displayName`
    /// on load and after each save. `pendingName` is derived from this.
    @Published var nameDraft: String = ""

    /// The trimmed draft if (and only if) it differs from the current filename.
    /// Applied by Save before metadata is written.
    var pendingName: String? {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != displayName else { return nil }
        return trimmed
    }

    /// True if the file's TIFF `Software` tag shows it was previously saved by this app.
    @Published var wasEditedByApp: Bool = false

    var isDirty: Bool {
        let metaDirty: Bool = {
            guard let e = edits, let o = originalEdits else { return false }
            return e != o
        }()
        return metaDirty || pendingName != nil
    }

    /// Tag value this app stamps into TIFF.Software on every write, and looks for on load.
    static let appSoftwareTag = "ExifViewer 1.0"

    /// Reads TIFF.Software and reports whether it was last saved by ExifViewer.
    static func checkEditedByApp(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let sw = tiff[kCGImagePropertyTIFFSoftware] as? String
        else { return false }
        return sw.hasPrefix("ExifViewer")
    }

    init(url: URL) {
        self.url = url
    }

    var displayName: String { url.lastPathComponent }

    /// Generates a thumbnail using ImageIO (fast, no full decode).
    static func makeThumbnail(url: URL, maxPixelSize: Int = 200) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - JPG discovery helpers

enum JPGFinder {
    private static let exts: Set<String> = ["jpg", "jpeg", "JPG", "JPEG"]

    /// Expand a list of dropped/opened URLs into a flat list of JPG file URLs.
    /// Folders are walked recursively. Order is preserved; duplicates removed.
    static func collectJPGs(from urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for url in urls {
            for found in expand(url) {
                let key = found.standardizedFileURL.path
                if !seen.contains(key) {
                    seen.insert(key)
                    out.append(found)
                }
            }
        }
        return out
    }

    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if isDir.boolValue {
            guard let en = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var results: [URL] = []
            for case let f as URL in en {
                if exts.contains(f.pathExtension) { results.append(f) }
            }
            // Stable sort by path so folder traversal order is deterministic.
            results.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return results
        } else {
            return exts.contains(url.pathExtension) ? [url] : []
        }
    }
}
