import SwiftUI
import KotlinSharedUI

public struct ListErrorView: View {
    private let error: KotlinThrowable
    @Environment(\.openURL) private var openURL
    private let onRetry: () -> Void

    public init(error: KotlinThrowable, onRetry: @escaping () -> Void) {
        self.error = error
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let expiredError = error as? LoginExpiredException {
                Image(systemName: "person.badge.shield.exclamationmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text("error_login_expired \(expiredError.accountKey)", bundle: FlareAppleUILocalization.bundle)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                Button {
                    if let url = reloginURL(
                        accountKey: expiredError.accountKey,
                        platformId: expiredError.platformId
                    ) {
                        openURL(url)
                    }
                } label: {
                    Text("error_login_expired_action", bundle: FlareAppleUILocalization.bundle)
                }
                .buttonStyle(.borderedProminent)
            } else if let reloginError = error as? RequireReLoginException {
                Image(systemName: "person.badge.shield.exclamationmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text("permission_denied_title", bundle: FlareAppleUILocalization.bundle)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                Text("permission_denied_message", bundle: FlareAppleUILocalization.bundle)
                Button {
                    if let url = reloginURL(
                        accountKey: reloginError.accountKey,
                        platformId: reloginError.platformId
                    ) {
                        openURL(url)
                    }
                } label: {
                    Text("error_login_expired_action", bundle: FlareAppleUILocalization.bundle)
                }
                .buttonStyle(.borderedProminent)
            } else  {
                // exclamationmark.triangle.text.page 是 iOS 17 才有的符号，iOS 15/16 上
                // 画不出来（错误页会只剩文字）。统一用 iOS 13 起就有的三角形。
                Image(systemName: "exclamationmark.triangle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
                Text("error", bundle: FlareAppleUILocalization.bundle)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                Button {
                    onRetry()
                } label: {
                    Text("action_retry", bundle: FlareAppleUILocalization.bundle)
                }
                .buttonStyle(.borderedProminent)
                // 真实原因放大 + 可长按选中，方便直接复制/截图反馈。
                VStack(alignment: .leading, spacing: 4) {
                    if let message = error.message, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    } else {
                        Text(String(describing: error))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    Text(String(describing: type(of: error)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.flareSystemGroupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
            }
        }
        .padding()
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
