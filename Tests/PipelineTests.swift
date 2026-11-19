import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct TestFailure: Error, CustomStringConvertible { let description: String }

@main
struct PipelineTests {
    static var fm: FileManager { .default }
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }
    static func create(_ folder: URL, _ name: String) throws -> URL {
        let path = folder.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    static func make(width: Int, height: Int, alpha: Bool = true, bin: CGColorSpace = sRGB,
        draw: (CGContext) -> Void) -> CGImage {
        let canvas = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: bin,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(canvas)
        return canvas.makeImage()!
    }
    static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int = 1) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 0.95
        ] as CFDictionary)
        try check(CGImageDestinationFinalize(destination), "Couldn’t create fixture \(url.lastPathComponent)")
    }
    static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TestFailure(description: "Couldn’t read \(url.lastPathComponent)")
        }
        return image
    }
    static func sample(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let canvas = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }
    static func settings(_ format: ExportFormat, edge: Int, quality: Double = 0.85, matte: String = "FFFFFF") -> ExportSettings {
        ExportSettings(format: format, maxEdge: edge, quality: quality, matteHex: matte)
    }

    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let root = try create(fm.temporaryDirectory, "pixel-crouton-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let input = try create(root, "input")
        let nested = try create(input, "nested")
        let out = try create(root, "export")
        let shape = make(width: 160, height: 80) {
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 45, height: 80))
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
            $0.fill(CGRect(x: 45, y: 0, width: 50, height: 80))
        }
        let alpha = input.appendingPathComponent("Studio Render.png")
        try write(shape, to: alpha, type: .png)
        let originalBytes = try Data(contentsOf: alpha)

        let png = try ImageExporter(folder: out, settings: settings(.png, edge: 80))
        let downsized = try read(png.export(alpha))
        try check(downsized.width == 80 && downsized.height == 40, "Resize dimensions don’t preserve aspect ratio")
        try check(sample(downsized, x: 65, y: 20)[3] == 0, "PNG lost fully transparent pixels")
        let semitransparent = sample(downsized, x: 34, y: 20)
        try check((122...134).contains(semitransparent[3]), "PNG lost semitransparency")
        try check(sample(downsized, x: 5, y: 20)[0] > 245, "PNG shifted opaque red")

        let jpeg = try ImageExporter(folder: out, settings: settings(.jpeg, edge: 2000, matte: "00FF00"))
        let converted = try read(jpeg.export(alpha))
        try check(converted.width == 160 && converted.height == 80, "Small source was enlarged")
        let green = sample(converted, x: 138, y: 40)
        try check(green[0] < 14 && green[1] > 235 && green[2] < 14 && green[3] == 255, "JPEG did not apply selected matte")
        let blend = sample(converted, x: 70, y: 40)
        try check((105...150).contains(blend[0]) && (105...150).contains(blend[1]) && blend[2] < 20,
            "JPEG did not composite the half-transparent edge against the chosen matte")
        let white = try ImageExporter(folder: out, settings: settings(.jpeg, edge: 2000))
        let whitePixel = try sample(read(white.export(alpha)), x: 138, y: 40)
        try check(whitePixel.allSatisfy { $0 > 245 }, "Default JPEG matte is not white")

        let oriented = nested.appendingPathComponent("Portrait Test.jpg")
        let colored = make(width: 96, height: 48, alpha: false) {
            $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            $0.fill(CGRect(x: 48, y: 0, width: 48, height: 48))
        }
        try write(colored, to: oriented, type: .jpeg, orientation: 6)
        let upright = try read(white.export(oriented))
        try check(upright.width == 48 && upright.height == 96, "EXIF orientation wasn’t baked into dimensions")
        try check(sample(upright, x: 24, y: 15)[0] > 235 && sample(upright, x: 24, y: 80)[2] > 235,
            "EXIF orientation did not rotate pixel content correctly")
        let p3 = nested.appendingPathComponent("Wide Gamut.png")
        let p3Space = CGColorSpace(name: CGColorSpace.displayP3)!
        let swatch = make(width: 48, height: 50, alpha: false, bin: p3Space) {
            $0.setFillColor(CGColor(colorSpace: p3Space, components: [0.8, 0.3, 0.5, 1])!)
            $0.fill(CGRect(x: 0, y: 0, width: 48, height: 50))
        }
        try write(swatch, to: p3, type: .png)
        let p3Export = try read(png.export(p3))
        let initialProfile = try read(p3).colorSpace?.copyICCData()
        try check(initialProfile != nil && p3Export.colorSpace?.copyICCData() == initialProfile, "PNG wide gamut RGB profile changed")
        let referencePixel = try sample(read(p3), x: 20, y: 20)
        try check(zip(referencePixel, sample(p3Export, x: 20, y: 20)).allSatisfy { abs($0 - $1) <= 2 }, "PNG wide gamut colors changed")
        let jpegP3 = try read(white.export(p3))
        try check(jpegP3.colorSpace?.copyICCData() == initialProfile, "JPEG wide gamut RGB profile changed")

        let duplicate = nested.appendingPathComponent("STUDIO RENDER.png")
        try fm.copyItem(at: alpha, to: duplicate)
        let sameFolder = try ImageExporter(folder: input, settings: settings(.png, edge: 80))
        let sameFolderOutput = try sameFolder.export(alpha)
        let collision = try sameFolder.export(duplicate)
        let repeatRun = try ImageExporter(folder: input, settings: settings(.png, edge: 80))
        let repeated = try repeatRun.export(alpha)
        try check(sameFolderOutput.lastPathComponent == "Studio Render-2.png" &&
            collision.lastPathComponent == "STUDIO RENDER-3.png" &&
            repeated.lastPathComponent == "Studio Render-4.png", "Case-insensitive overwrite avoidance or repeat-run suffix failed")
        let unchanged = try Data(contentsOf: alpha)
        try check(unchanged == originalBytes, "The original changed")
        let corrupt = input.appendingPathComponent("Corrupt Image.png")
        try Data("not a PNG".utf8).write(to: corrupt)
        try Data("not an image".utf8).write(to: input.appendingPathComponent("Notes.txt"))

        let scan = InputDiscovery.scan([input, nested, oriented])
        try check(scan.urls.count == 8 && scan.urls.contains(corrupt.resolvingSymlinksInPath()) && scan.ignored == 1 &&
            scan.issues.isEmpty, "Unexpected recursive scan, deduplication, or unsupported-file result: \(scan.urls)")
        let beforeWrite = try create(root, "before-write")
        let racer = try ImageExporter(folder: beforeWrite, settings: settings(.png, edge: 80))
        let racedFile = beforeWrite.appendingPathComponent("Studio Render.png")
        let sentinel = Data("Do not overwrite".utf8)
        try sentinel.write(to: racedFile)
        let racerOutput = try racer.export(alpha)
        let racedBytes = try Data(contentsOf: racedFile)
        try check(racerOutput.lastPathComponent == "Studio Render-2.png" &&
            racedBytes == sentinel, "Concurrent newly-created output was overwritten")

        let namedOut = try create(root, "naming")
        let hero = namedOut.appendingPathComponent("hero.png")
        try write(shape, to: hero, type: .png)
        let originalHero = try Data(contentsOf: hero)
        let variants: [(ExportNaming, ExportFormat, String)] = [
            (ExportNaming(), .jpeg, "hero.jpg"),
            (ExportNaming(prefix: "studio_"), .jpeg, "studio_hero.jpg"),
            (ExportNaming(suffix: "-1600w"), .png, "hero-1600w.png"),
            (ExportNaming(prefix: "studio_", suffix: "-1600w"), .jpeg, "studio_hero-1600w.jpg"),
            (ExportNaming(prefix: "現場 ", suffix: ".v2"), .png, "現場 hero.v2.png")
        ]
        for (naming, format, expected) in variants {
            var namedSettings = settings(format, edge: 80)
            namedSettings.naming = naming
            let engine = try ImageExporter(folder: namedOut, settings: namedSettings)
            let file = try engine.export(hero)
            try check(naming.filename(for: hero, format: format) == expected &&
                file.lastPathComponent == expected, "Naming preview and output mismatch: \(expected)")
        }
        let namedSettings = ExportSettings(format: .png, maxEdge: 80, quality: 0.85, matteHex: "FFFFFF",
            naming: ExportNaming(prefix: "STUDIO_", suffix: "-1600w"))
        let caseOriginal = namedOut.appendingPathComponent("studio_hero-1600w.png")
        try sentinel.write(to: caseOriginal)
        let firstEngine = try ImageExporter(folder: namedOut, settings: namedSettings)
        let first = try firstEngine.export(hero)
        let secondEngine = try ImageExporter(folder: namedOut, settings: namedSettings)
        let second = try secondEngine.export(hero)
        let kept = try Data(contentsOf: caseOriginal)
        let heroAfter = try Data(contentsOf: hero)
        try check(first.lastPathComponent == "STUDIO_hero-1600w-2.png" &&
            second.lastPathComponent == "STUDIO_hero-1600w-3.png" && kept == sentinel && heroAfter == originalHero,
            "Named collision or original preservation failed")

        func concurrentNamedExport() async throws -> URL {
            try await Task.detached {
                let engine = try ImageExporter(folder: namedOut, settings: namedSettings)
                return try engine.export(hero)
            }.value
        }
        async let raceOne = concurrentNamedExport()
        async let raceTwo = concurrentNamedExport()
        let racedNames = try await Set([raceOne.lastPathComponent, raceTwo.lastPathComponent])
        try check(racedNames == ["STUDIO_hero-1600w-4.png", "STUDIO_hero-1600w-5.png"], "Concurrent named exports did not pick different files")

        for affix in ["../", "/", "\\", ":", "\n", "\u{0000}", String(repeating: "é", count: 100)] {
            for naming in [ExportNaming(prefix: affix), ExportNaming(suffix: affix)] {
                try check(naming.validationMessage != nil, "Unsafe prefix/suffix wasn’t rejected")
                var unsafeSettings = settings(.png, edge: 80)
                unsafeSettings.naming = naming
                do {
                    _ = try ImageExporter(folder: namedOut, settings: unsafeSettings)
                    throw TestFailure(description: "Unsafe prefix/suffix reached the exporter")
                } catch ExportError.invalidName { /* expected */ }
            }
        }
        let longStem = String(repeating: "A", count: 235) + ".png"
        let longInput = namedOut.appendingPathComponent(longStem)
        try write(shape, to: longInput, type: .png)
        let longFile = try firstEngine.export(longInput)
        try check(longFile.lastPathComponent.hasPrefix("STUDIO_") &&
            longFile.lastPathComponent.hasSuffix("-1600w.png") &&
            longFile.lastPathComponent.utf8.count <= 255, "Long stems must retain both affixes")

        let detailed = root.appendingPathComponent("Large Image.jpg")
        let art = make(width: 6000, height: 4000, alpha: false) { ctx in
            var random: UInt64 = 5503
            func tone() -> CGFloat {
                random = 2862933555777941757 &* random &+ 3037000493
                return CGFloat((random >> 32) & 255) / 255
            }
            for y in stride(from: 0, to: 4000, by: 24) {
                for x in stride(from: 0, to: 6000, by: 24) {
                    ctx.setFillColor(red: tone(), green: tone(), blue: tone(), alpha: 1)
                    ctx.fill(CGRect(x: x, y: y, width: 24, height: 24))
                }
            }
        }
        try write(art, to: detailed, type: .jpeg)
        let highQuality = try ImageExporter(folder: out, settings: settings(.jpeg, edge: 2000, quality: 0.95))
        let lowQuality = try ImageExporter(folder: out, settings: settings(.jpeg, edge: 2000, quality: 0.25))
        let highFile = try highQuality.export(detailed)
        let lowFile = try lowQuality.export(detailed)
        let reduced = try read(highFile)
        let highBytes = try Data(contentsOf: highFile).count
        let lowBytes = try Data(contentsOf: lowFile).count
        try check(reduced.width == 2000 && abs(reduced.height - 1333) <= 1, "Large source resize did not honor the requested aspect and edge")
        try check(highBytes > lowBytes, "JPEG quality did not affect compression")

        let large = try create(root, "large-batch")
        let batchOut = try create(root, "batch-export")
        let fixture = make(width: 8, height: 6) {
            $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let tiny = large.appendingPathComponent("base.png")
        try write(fixture, to: tiny, type: .png)
        let batchCount = 500
        var batch = [corrupt]
        for index in 0..<batchCount {
            let url = large.appendingPathComponent("Sample-\(index).png")
            try fm.copyItem(at: tiny, to: url)
            batch.append(url)
        }
        let outcome = await BatchRunner.run(batch, folder: batchOut, settings: settings(.jpeg, edge: 6)) { _, _ in }
        let exported = try fm.contentsOfDirectory(atPath: batchOut.path)
        try check(outcome.completed == batchCount && outcome.failures.count == 1 && exported.count == batchCount,
            "Large batch stopped early, omitted failures, or left stray staging files")
        try check(outcome.failures[0].message.contains("Preview"), "Corrupt-file failure isn’t actionable")
        let cancelOut = try create(root, "cancel-export")
        let cancelled = await BatchRunner.run(Array(batch.dropFirst()), folder: cancelOut, settings: settings(.png, edge: 8)) { index, _ in
            if index == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let cancelledFiles = try fm.contentsOfDirectory(atPath: cancelOut.path)
        try check(cancelled.cancelled && cancelled.completed == 3 && cancelledFiles.count == 3, "Cancellation didn’t preserve completed files or stop before the next")
        if CommandLine.arguments.count > 1 {
            let demo = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let demoInputs = try create(demo, "Sample Images")
            let demoOutput = try create(demo, "Exported Images")
            for file in [alpha, oriented, p3, corrupt] {
                let destination = demoInputs.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: file, to: destination) }
            }
            print("UI sample inputs: \(demoInputs.path); output: \(demoOutput.path)")
        }
        print("PASS: dimensions, no upscaling, EXIF orientation, PNG alpha, JPEG white/custom matte + half-alpha edge, wide-gamut profiles, recursive import, case collisions/repeats/race, originals, corrupt-input continuation, large-source resize, JPEG quality, independent affixes, invalid names, filename races, 500-image batch and cancellation")
    }
}
