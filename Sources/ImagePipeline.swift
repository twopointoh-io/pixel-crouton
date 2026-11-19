import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG", png = "PNG"
    var id: Self { self }
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    var type: UTType { self == .jpeg ? .jpeg : .png }
    var subtitle: String { self == .jpeg ? "Smaller files for the web" : "Lossless, keeps transparency" }
}

struct ExportSettings: Sendable {
    let format: ExportFormat
    let maxEdge: Int
    let quality: Double
    let matteHex: String
    var naming = ExportNaming()
    static let maxAllowedEdge = 12_000
    static let defaults = ExportSettings(format: .jpeg, maxEdge: 2000, quality: 0.85, matteHex: "FFFFFF")

    static func hexComponents(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let value = UInt32(hex, radix: 16) ?? 0xffffff
        return (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
    }
}

struct ExportNaming: Sendable {
    var prefix = ""
    var suffix = ""
    private static let maximumAffixBytes = 140

    var validationMessage: String? {
        if [prefix, suffix].contains(where: {
            $0.contains("/") || $0.contains("\\") || $0.contains(":") || $0.rangeOfCharacter(from: .controlCharacters) != nil
        }) {
            return "Remove slashes, backslashes, colons, and control characters from the name."
        }
        if prefix.utf8.count + suffix.utf8.count > Self.maximumAffixBytes {
            return "Shorten the prefix or suffix so there’s room for the original name."
        }
        return nil
    }

    func filename(for input: URL, format: ExportFormat) -> String {
        stem(for: input) + "." + format.fileExtension
    }

    func stem(for input: URL) -> String {
        let stem = input.deletingPathExtension().lastPathComponent
        let source = stem.isEmpty || stem == "." || stem == ".." ? "image" : stem
        // Leave space under the filesystem name limit for the extension and a collision counter.
        // Preserve the complete prefix and suffix even when the original stem needs shortening.
        let budget = max(0, 225 - prefix.utf8.count - suffix.utf8.count)
        var shortened = ""
        var bytes = 0
        for character in source {
            let length = String(character).utf8.count
            if bytes + length > budget { break }
            bytes += length
            shortened.append(character)
        }
        return prefix + (shortened.isEmpty ? "image" : shortened) + suffix
    }
}

enum ExportError: LocalizedError {
    case badSettings, invalidName(String), unavailableFolder, unreadable, invalidDimensions, decode, matte, encode, save(Int32)
    var errorDescription: String? {
        switch self {
        case .badSettings: return "Use a maximum edge between 1 and \(ExportSettings.maxAllowedEdge) px and quality between 1% and 100%."
        case let .invalidName(message): return message
        case .unavailableFolder: return "The export folder is unavailable. Choose an existing, writable folder."
        case .unreadable: return "Image I/O couldn’t read this file. Open it in Preview or re-save it in a supported format."
        case .invalidDimensions: return "The file has missing or invalid pixel dimensions. Try re-saving it in Preview."
        case .decode: return "The image could not be decoded. Check that it’s intact or try re-saving it in Preview."
        case .matte: return "There wasn’t enough space to process this image. Try a smaller maximum edge or close other apps."
        case .encode: return "The image couldn’t be written. Check free space or choose another export folder."
        case let .save(code): return "Couldn’t save the export (\(String(cString: strerror(code)))). Check permissions and free space, or select another folder."
        }
    }
}

struct InputIssue: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let message: String
}

struct InputScan: Sendable {
    var urls: [URL] = []
    var issues: [InputIssue] = []
    var ignored = 0
}

enum InputDiscovery {
    private static let extraExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
        "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "jxl", "ico", "icns"
    ]
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]

    static func scan(_ selections: [URL]) -> InputScan {
        let fm = FileManager.default
        var result = InputScan()
        var seen: Set<URL> = []
        func add(_ url: URL) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            if seen.insert(canonical).inserted { result.urls.append(canonical) }
        }
        for url in selections where !Task.isCancelled {
            if let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true, values.isPackage != true {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { path, error in
                        result.issues.append(InputIssue(url: path, message: "Couldn’t scan this location: \(error.localizedDescription)"))
                        return true
                    })
                while let child = items?.nextObject() as? URL, !Task.isCancelled {
                    autoreleasepool {
                        guard let vals = try? child.resourceValues(forKeys: keys) else {
                            result.issues.append(InputIssue(url: child, message: "Couldn’t check this file. Check its Finder permissions."))
                            return
                        }
                        if vals.isDirectory == true { return }
                        guard vals.isRegularFile == true, vals.isSymbolicLink != true else { result.ignored += 1; return }
                        let ext = child.pathExtension.lowercased()
                        if extraExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
                            add(child)
                        } else {
                            result.ignored += 1
                        }
                    }
                }
            } else {
                // Explicit selections are given a chance even without a recognizable extension.
                add(url)
            }
        }
        return result
    }
}

final class ImageExporter {
    private let folder: URL
    private let settings: ExportSettings
    private var occupied: Set<String>
    private var nextSuffix: [String: Int] = [:]

    init(folder: URL, settings: ExportSettings) throws {
        guard (1...ExportSettings.maxAllowedEdge).contains(settings.maxEdge),
            (0.01...1.0).contains(settings.quality) else { throw ExportError.badSettings }
        if let error = settings.naming.validationMessage { throw ExportError.invalidName(error) }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
            let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            throw ExportError.unavailableFolder
        }
        self.folder = folder
        self.settings = settings
        self.occupied = Set(entries.map(Self.collisionKey))
    }

    func export(_ input: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(input as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 else {
            throw ExportError.unreadable
        }
        let frame = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0,
            let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0 else {
            throw ExportError.invalidDimensions
        }
        let target = min(settings.maxEdge, max(width, height))
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, frame, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, frame) == .statusComplete else {
            throw ExportError.decode
        }
        if settings.format == .jpeg {
            switch image.alphaInfo {
            case .none, .noneSkipLast, .noneSkipFirst: break
            default: image = try flattened(image)
            }
        }

        // Encode privately beside the final output so publishing can be an atomic exclusive rename.
        let temporary = folder.appendingPathComponent(".pixel-crouton-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, settings.format.type.identifier as CFString, 1, nil) else { throw ExportError.encode }
        let options: CFDictionary? = settings.format == .jpeg ?
            [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.encode }

        let base = settings.naming.stem(for: input)
        let ext = settings.format.fileExtension
        let series = Self.collisionKey(base + "." + ext)
        var count = nextSuffix[series, default: 1]
        while true {
            let name = count == 1 ? "\(base).\(ext)" : "\(base)-\(count).\(ext)"
            let key = Self.collisionKey(name)
            if !occupied.contains(key) {
                let output = folder.appendingPathComponent(name)
                let error = Self.publish(temporary, as: output)
                if error == 0 {
                    occupied.insert(key)
                    nextSuffix[series] = count + 1
                    return output
                }
                guard error == EEXIST else { throw ExportError.save(error) }
                occupied.insert(key)
            }
            count += 1
        }
    }

    private func flattened(_ image: CGImage) throws -> CGImage {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let canvas = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace ?? sRGB,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) ??
                CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ExportError.matte }
        let (r, g, b) = ExportSettings.hexComponents(settings.matteHex)
        if let matte = CGColor(colorSpace: sRGB, components: [r, g, b, 1]) { canvas.setFillColor(matte) }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        canvas.fill(bounds)
        canvas.draw(image, in: bounds)
        guard let flattened = canvas.makeImage() else { throw ExportError.matte }
        return flattened
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func publish(_ temporary: URL, as output: URL) -> Int32 {
        temporary.withUnsafeFileSystemRepresentation { from in
            output.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
                let failure = errno
                guard failure == ENOTSUP || failure == EINVAL else { return failure }
                // Volumes that don’t support exclusive rename still must never replace a file.
                return copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 ? 0 : errno
            }
        }
    }
}

struct BatchOutcome: Sendable {
    var completed = 0
    var failures: [InputIssue] = []
    var setupError: String?
    var cancelled = false
}

enum BatchRunner {
    static func run(_ urls: [URL], folder: URL, settings: ExportSettings,
        progress: @MainActor (Int, InputIssue?) -> Void) async -> BatchOutcome {
        var result = BatchOutcome()
        let exporter: ImageExporter
        do { exporter = try ImageExporter(folder: folder, settings: settings) }
        catch { result.setupError = error.localizedDescription; return result }
        for (index, input) in urls.enumerated() {
            if Task.isCancelled { result.cancelled = true; break }
            let issue: InputIssue? = autoreleasepool {
                do { _ = try exporter.export(input); return nil }
                catch { return InputIssue(url: input, message: error.localizedDescription) }
            }
            if let issue { result.failures.append(issue) } else { result.completed += 1 }
            await progress(index + 1, issue)
        }
        return result
    }
}
