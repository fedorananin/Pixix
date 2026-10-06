import AppKit
import PixixCodec

/// A row of thumbnails for the folder being browsed.
final class FilmstripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let height: CGFloat = 84

    var onSelect: ((Int) -> Void)?
    private var files: [URL] = []
    private var isSyncingSelection = false
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 68, height: 68)
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.identifier)

        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reload(files: [URL], index: Int) {
        if files != self.files {
            self.files = files
            collection.reloadData()
        }
        guard files.indices.contains(index) else { return }
        let path = IndexPath(item: index, section: 0)
        isSyncingSelection = true
        collection.selectionIndexPaths = [path]
        collection.animator().scrollToItems(at: [path], scrollPosition: .centeredHorizontally)
        isSyncingSelection = false
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        files.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FilmstripItem.identifier, for: indexPath)
        (item as? FilmstripItem)?.configure(url: files[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isSyncingSelection, let path = indexPaths.first else { return }
        onSelect?(path.item)
    }
}

private final class FilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("filmstrip")
    private static let cache = NSCache<NSURL, CGImage>()
    private var task: Task<Void, Never>?
    private var url: URL?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 5
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override var isSelected: Bool {
        didSet { view.layer?.borderWidth = isSelected ? 3 : 0 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        view.layer?.contents = nil
    }

    func configure(url: URL) {
        self.url = url
        view.toolTip = url.lastPathComponent
        if let hit = Self.cache.object(forKey: url as NSURL) {
            view.layer?.contents = hit
            return
        }
        task = Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                try? ImageSource(url: url).image(maxPixelSize: 160)
            }.value
            guard let self, let image, !Task.isCancelled, self.url == url else { return }
            Self.cache.setObject(image, forKey: url as NSURL)
            self.view.layer?.contents = image
        }
    }
}
