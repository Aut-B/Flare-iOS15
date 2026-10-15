import SwiftUI
import UIKit

final class TimelineHostedAccessoryView: UIView {
    var onHeightChanged: (() -> Void)?
    private var measuredHeight: CGFloat?
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    init() {
        super.init(frame: .zero)
        // iOS 15 回退：safeAreaRegions 是 iOS 16.4 API，sizingOptions 是 iOS 16 API；
        // 两者都只影响安全区与自动尺寸，iOS 15 下靠手动测量高度（layoutSubviews）。
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
            host.sizingOptions = [.intrinsicContentSize]
        }
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ content: AnyView) {
        host.rootView = content
        host.view.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1 else { return }
        let height = host.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        guard height.isFinite, height > 0, measuredHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
        measuredHeight = height
        onHeightChanged?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            host.willMove(toParent: nil)
            host.removeFromParent()
        } else if host.parent == nil {
            var responder: UIResponder? = next
            while let current = responder {
                if let parent = current as? UIViewController {
                    parent.addChild(host)
                    host.didMove(toParent: parent)
                    break
                }
                responder = current.next
            }
        }
    }
}
