// Renders an HTML page to a 1200x630 PNG for use as a share image (og:image).
// Usage: swift scripts/og/render.swift <page.html[?query]> <out.png>

import AppKit
import WebKit

let width = 1200
let height = 630

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError
    .write(Data("usage: render.swift <page.html[?query]> <out.png>\n".utf8))
  exit(2)
}

let parts = arguments[1].split(separator: "?", maxSplits: 1).map(String.init)
let file = URL(fileURLWithPath: parts[0]).standardizedFileURL
var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
if parts.count == 2 {
  components.query = parts[1]
}

let page = components.url!
let output = URL(fileURLWithPath: arguments[2])
/// Let the page load images from anywhere in the repository.
let readRoot = file.deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()

final class Renderer: NSObject, WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
    // Give images and fonts a moment to settle before the snapshot.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      let config = WKSnapshotConfiguration()
      config.rect = CGRect(x: 0, y: 0, width: width, height: height)
      webView.takeSnapshot(with: config) { image, error in
        guard let image else {
          FileHandle.standardError
            .write(Data("snapshot failed: \(String(describing: error))\n".utf8))
          exit(1)
        }
        // Draw into an exact 1200x630 bitmap, downsampling a Retina snapshot.
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        do {
          try rep.representation(using: .png, properties: [:])!.write(to: output)
          print("wrote \(output.path)")
          exit(0)
        } catch {
          FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
          exit(1)
        }
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let frame = NSRect(x: -10000, y: -10000, width: width, height: height)
let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
let renderer = Renderer()
webView.navigationDelegate = renderer
window.contentView = webView
window.orderFrontRegardless()

webView.loadFileURL(page, allowingReadAccessTo: readRoot)
app.run()
