// DesignScoreCapture.swift: the SwiftUI adapter of the design match score (claude-config#1364).
//
// Copy this file into the app's UI snapshot test target (it is test code: it renders real views to
// pictures). A test then draws the BUILT side of every frame of the settled design:
//
//     @MainActor func testMatchesTheSettledDesign() throws {
//         let fixture = try DesignFixture.load()                 // the committed fixture
//         try DesignScoreCapture.capture(
//             folder: URL(fileURLWithPath: ProcessInfo.processInfo.environment["DESIGN_SCORE_CAPTURE"]!),
//             build: "InvoiceListView",
//             view: { frame in AnyView(InvoiceListView(model: fixture.model(for: frame))) },
//             checks: { frame, model in [...] })
//     }
//
// The DESIGN side is drawn first by the web adapter, which renders the settled HTML file's frames in a
// browser: `node capture-web.mjs --design <settled.html> --out <folder> --design-only`. That leaves
// capture.json and <id>-design.png per frame; this fills in <id>-built.png and each frame's checks,
// renders each view at the size its design picture was drawn (the frame's own width), at scale 1, in
// sRGB, and marks the capture swiftui. `design_score.py score <folder>` then scores it, the same score
// and the same format as on web.
//
// The decision checks are Swift here, since a SwiftUI view has no DOM: each frame's closure returns
// one DesignScoreCheck per decision the map verifies by a check on that frame. They cannot run on the
// HTML design, so the capture carries no positive control for them, and the score says so.
//
// Every fault throws (a missing capture, a frame with no design picture, a view that renders to
// nothing), so the test fails rather than writing a capture that scores as unmeasured silently.
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

public struct DesignScoreCheck: Sendable {
    public let id: String
    public let ok: Bool
    public let detail: String
    public init(_ id: String, ok: Bool, detail: String = "") {
        self.id = id
        self.ok = ok
        self.detail = detail
    }
}

public enum DesignScoreCaptureError: Error, CustomStringConvertible {
    case unreadable(String)
    case render(String)

    public var description: String {
        switch self {
        case .unreadable(let why): return "design score capture could not be read: \(why)"
        case .render(let why): return "design score capture could not render: \(why)"
        }
    }
}

@MainActor
public enum DesignScoreCapture {
    /// Draws the built side of every frame in `folder`'s capture and writes the capture back.
    public static func capture(
        folder: URL,
        build: String,
        commit: String? = ProcessInfo.processInfo.environment["DESIGN_SCORE_COMMIT"],
        dirty: Bool? = ProcessInfo.processInfo.environment["DESIGN_SCORE_DIRTY"].map { $0 == "1" },
        view: (String) -> AnyView,
        checks: (String) -> [DesignScoreCheck]
    ) throws {
        let captureURL = folder.appendingPathComponent("capture.json")
        guard let data = try? Data(contentsOf: captureURL),
              var capture = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              capture["format"] as? String == "design-capture",
              var frames = capture["frames"] as? [[String: Any]], !frames.isEmpty else {
            throw DesignScoreCaptureError.unreadable("\(captureURL.path) holds no design capture with frames; run capture-web.mjs --design-only first")
        }
        for index in frames.indices {
            guard let id = frames[index]["id"] as? String,
                  let designName = frames[index]["designImage"] as? String else {
                throw DesignScoreCaptureError.unreadable("frame \(index + 1) has no id or design picture")
            }
            let size = try pictureSize(folder.appendingPathComponent(designName))
            let builtName = "\(id)-built.png"
            try render(view(id), width: size.width, height: size.height,
                       to: folder.appendingPathComponent(builtName))
            frames[index]["builtImage"] = builtName
            frames[index]["checks"] = checks(id).map { ["id": $0.id, "ok": $0.ok, "detail": $0.detail] }
            // The checks above are Swift; the design's own checks are JavaScript and test other code,
            // so they are no positive control for these.
            frames[index].removeValue(forKey: "designChecks")
            frames[index].removeValue(forKey: "builtError")
        }
        capture["frames"] = frames
        capture["platform"] = "swiftui"
        capture["build"] = build
        capture["commit"] = commit ?? NSNull()
        capture["dirty"] = dirty ?? NSNull()
        capture["capturedAt"] = ISO8601DateFormatter().string(from: Date())
        let out = try JSONSerialization.data(withJSONObject: capture, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: captureURL, options: .atomic)
    }

    /// The pixel size of a PNG, read from the file rather than trusted from a caller.
    static func pictureSize(_ url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw DesignScoreCaptureError.unreadable("the design picture \(url.path) could not be read")
        }
        return (width, height)
    }

    /// Renders `view` at exactly `width` by `height` points, at scale 1, into an sRGB PNG.
    static func render(_ view: AnyView, width: Int, height: Int, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height)))
        renderer.scale = 1
        guard let drawn = renderer.cgImage else {
            throw DesignScoreCaptureError.render("the view drew nothing for \(url.lastPathComponent)")
        }
        // Into sRGB, whatever space the renderer drew in, so a channel compares with the browser's.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DesignScoreCaptureError.render("no sRGB context for \(url.lastPathComponent)")
        }
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DesignScoreCaptureError.render("\(url.lastPathComponent) could not be written")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw DesignScoreCaptureError.render("\(url.lastPathComponent) could not be written")
        }
    }
}
