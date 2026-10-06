import AppKit
import PixixCodec
import SwiftUI

/// The popover behind the Info button.
final class InfoViewController: NSHostingController<InfoView> {
    init(url: URL) {
        super.init(rootView: InfoView(details: ImageDetails.read(url: url)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

struct InfoView: View {
    let details: ImageDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
