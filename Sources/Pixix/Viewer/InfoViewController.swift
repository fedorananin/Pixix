import AppKit
import PixixCodec
import SwiftUI

/// The popover behind the Info button.
final class InfoViewController: NSHostingController<InfoView> {
    /// `image` is what is on screen; the histogram is counted from it.
    init(url: URL, image: CGImage?) {
        super.init(rootView: InfoView(details: ImageDetails.read(url: url), histogram: image.flatMap { Histogram(image: $0) }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct InfoView: View {
    let details: ImageDetails
    let histogram: Histogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let histogram, histogram.peak > 0 {
                HistogramView(histogram: histogram)
                    .frame(height: 72)
            }
            ForEach(details.sections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(row.value)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                    }
                    if section.title == "Location", let url = details.coordinate?.mapsURL {
                        Button("Open in Maps") { NSWorkspace.shared.open(url) }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

/// Red, green and blue laid over each other, with brightness as a pale outline on top.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            let peak = Double(max(histogram.peak, 1))
            func curve(_ counts: [Int], closed: Bool) -> Path {
                var path = Path()
                if closed { path.move(to: CGPoint(x: 0, y: size.height)) }
                for (level, count) in counts.enumerated() {
                    // The square root keeps the quiet tones visible next to the dominant ones.
                    let height = min(sqrt(Double(count) / peak), 1) * size.height
                    let point = CGPoint(x: Double(level) / 255 * size.width, y: size.height - height)
                    if level == 0, !closed { path.move(to: point) } else { path.addLine(to: point) }
                }
                if closed {
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                return path
            }
            context.blendMode = .screen
            context.fill(curve(histogram.red, closed: true), with: .color(Color(red: 0.95, green: 0.25, blue: 0.22)))
            context.fill(curve(histogram.green, closed: true), with: .color(Color(red: 0.2, green: 0.8, blue: 0.3)))
            context.fill(curve(histogram.blue, closed: true), with: .color(Color(red: 0.25, green: 0.45, blue: 1)))
            context.blendMode = .normal
            context.stroke(curve(histogram.luminance, closed: false), with: .color(.white.opacity(0.75)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Histogram")
    }
}
