import UIKit
import KotlinSharedUI

/// UIKit port of `ListErrorView`.
///
/// Matches the three cases of the SwiftUI implementation:
///   * `LoginExpiredException` → login-expired prompt with account key
///   * `RequireReLoginException` → permission-denied prompt
///   * everything else → generic error with retry + message
final class ListErrorUIView: UIView {
    var onOpenURL: ((URL) -> Void)?
    private var onRetry: (() -> Void)?
    private var actionURL: URL?

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .label
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .headline)
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()
    private let messageLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .body)
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()
    private let button: UIButton = {
        var cfg = UIButton.Configuration.borderedProminent()
        cfg.cornerStyle = .capsule
        let b = UIButton(configuration: cfg)
        return b
    }()
    private let detailLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .caption1)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(button)
        stack.addArrangedSubview(detailLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 16),
        ])
        button.addAction(UIAction { [weak self] _ in self?.handleButtonTap() }, for: .touchUpInside)
        // 错误详情可长按复制，方便把真实报错发出来定位。
        detailLabel.isUserInteractionEnabled = true
        detailLabel.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(copyDetail))
        )
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func copyDetail() {
        guard let text = detailLabel.text, !text.isEmpty else { return }
        UIPasteboard.general.string = text
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    enum Mode {
        case retry
        case openLogin
    }
    private var mode: Mode = .retry

    func configure(error: KotlinThrowable, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        detailLabel.isHidden = true
        messageLabel.isHidden = true

        if let expired = error as? LoginExpiredException {
            // person.badge.shield.exclamationmark 是 iOS 16 才有的符号，iOS 15 上会渲染成空白。
            iconView.image = UIImage(systemName: "exclamationmark.shield")
            titleLabel.text = String(format: String(localized: "error_login_expired %@"), "\(expired.accountKey)")
            button.setTitle(String(localized: "error_login_expired_action"), for: .normal)
            actionURL = reloginURL(accountKey: expired.accountKey, platformId: expired.platformId)
            mode = .openLogin
        } else if let reloginError = error as? RequireReLoginException {
            iconView.image = UIImage(systemName: "exclamationmark.shield")
            titleLabel.text = String(localized: "permission_denied_title")
            messageLabel.text = String(localized: "permission_denied_message")
            messageLabel.isHidden = false
            button.setTitle(String(localized: "error_login_expired_action"), for: .normal)
            actionURL = reloginURL(accountKey: reloginError.accountKey, platformId: reloginError.platformId)
            mode = .openLogin
        } else {
            // exclamationmark.triangle.text.page 是 iOS 17 才有的符号，换成 iOS 13 就有的。
            iconView.image = UIImage(systemName: "exclamationmark.triangle")
            titleLabel.text = String(localized: "error")
            button.setTitle(String(localized: "action_retry"), for: .normal)
            actionURL = nil
            mode = .retry
            let message = error.message ?? ""
            detailLabel.text = message.isEmpty
                ? String(describing: type(of: error))
                : "\(message)\n\(String(describing: type(of: error)))"
            detailLabel.isHidden = false
        }
    }

    private func handleButtonTap() {
        switch mode {
        case .retry:
            onRetry?()
        case .openLogin:
            if let url = actionURL { onOpenURL?(url) }
        }
    }

    private func reloginURL(accountKey: MicroBlogKey, platformId: String) -> URL? {
        URL(
            string: DeeplinkRoute.Relogin(
                accountKey: accountKey,
                platformId: platformId
            ).toUri()
        )
    }
}
