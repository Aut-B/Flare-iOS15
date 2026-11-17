import SwiftUI
import KotlinSharedUI

public struct AvatarView: View {
    @Environment(\.timelineAppearance.avatarShape) private var avatarShape
    private let data: UiMedia?

    public init(data: UiMedia?) {
        self.data = data
    }

    public init(data: String?, customHeader: [String: String]? = nil) {
        self.data = data.map { UiMediaImage(url: $0, proxy: ProxyRef.Global.shared, headers: customHeader) }
    }

    public var body: some View {
        NetworkImage(data: data)
            .clipShape(avatarShape == .circle ? FlareAnyShape(Circle()) : FlareAnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
    }
}
