import UIKit
import LiquidGlass

final class DemoViewController: UIViewController {
    private static let tileCount = 240
    private static let symbols = [
        "star.fill", "heart.fill", "bolt.fill", "moon.fill", "flame.fill", "leaf.fill",
        "cloud.fill", "drop.fill", "pawprint.fill", "bell.fill", "camera.fill", "music.note"
    ]

    private lazy var collectionView: UICollectionView = {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / 3), heightDimension: .absolute(110))
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(110)),
            subitems: [item]
        )
        let collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group))
        )
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.register(TileCell.self, forCellWithReuseIdentifier: TileCell.reuseIdentifier)
        return collectionView
    }()

    private let button = LiquidGlassView()
    private let card = LiquidGlassView()
    private let circle = LiquidGlassView()

    private lazy var backdropControl: UISegmentedControl = {
        let control = UISegmentedControl(items: ["Live", "Static"])
        control.selectedSegmentIndex = 1
        control.addAction(UIAction { [weak self] _ in self?.applyBackdrop() }, for: .valueChanged)
        return control
    }()

    private var glassViews: [LiquidGlassView] { [button, card, circle] }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Liquid Glass"
        view.backgroundColor = .black

        let panel = UIStackView(arrangedSubviews: [backdropControl])
        panel.isLayoutMarginsRelativeArrangement = true
        panel.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        panel.backgroundColor = .secondarySystemBackground

        view.addSubview(collectionView)
        glassViews.forEach(view.addSubview)
        view.addSubview(panel)
        ([collectionView, panel] + glassViews).forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: panel.topAnchor)
        ])

        configure(button, shape: .capsule, size: CGSize(width: 220, height: 64), below: collectionView.topAnchor, content: Self.makeLabel("Hold me"))
        configure(card, shape: .roundedRect(cornerRadius: 32), size: CGSize(width: 300, height: 140), below: button.bottomAnchor, content: Self.makeLabel("Glass card"))
        configure(circle, shape: .circle, size: CGSize(width: 88, height: 88), below: card.bottomAnchor, content: Self.makeIcon("sparkles"))
        button.addAction(UIAction { _ in print("Glass button tapped") }, for: .primaryActionTriggered)

        applyBackdrop()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        glassViews.forEach { $0.setNeedsBackdropUpdate() }
    }

    private func configure(_ glass: LiquidGlassView, shape: LiquidGlassStyle.Shape, size: CGSize, below anchor: NSLayoutYAxisAnchor, content: UIView) {
        glass.style.shape = shape
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: glass.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            glass.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glass.topAnchor.constraint(equalTo: anchor, constant: 48),
            glass.widthAnchor.constraint(equalToConstant: size.width),
            glass.heightAnchor.constraint(equalToConstant: size.height)
        ])
    }

    private func applyBackdrop() {
        let backdrop: LiquidGlassView.Backdrop = backdropControl.selectedSegmentIndex == 0 ? .live : .static
        glassViews.forEach { $0.backdrop = backdrop }
    }

    private static func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    private static func makeIcon(_ name: String) -> UIImageView {
        let icon = UIImageView(image: UIImage(systemName: name))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return icon
    }
}

extension DemoViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Self.tileCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TileCell.reuseIdentifier, for: indexPath)
        let index = indexPath.item
        (cell as? TileCell)?.configure(
            color: UIColor(hue: CGFloat((index * 37) % 360) / 360, saturation: 0.75, brightness: 0.95, alpha: 1),
            symbol: Self.symbols[index % Self.symbols.count],
            text: "Tile \(index)"
        )
        return cell
    }
}

private final class TileCell: UICollectionViewCell {
    static let reuseIdentifier = "TileCell"

    private let imageView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .bold)
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36)
        ])
        contentView.layer.borderColor = UIColor.black.cgColor
        contentView.layer.borderWidth = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(color: UIColor, symbol: String, text: String) {
        contentView.backgroundColor = color
        imageView.image = UIImage(systemName: symbol)
        label.text = text
    }
}
