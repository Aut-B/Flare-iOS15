import SwiftUI
import PhotosUI
import FlareAppleUI
import Perception
import NavigationBackport
import FlareAppleCore

struct AltTextEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var item: MediaItem
    let maxLength: Int
    
    var body: some View {
        NBNavigationStack {
            VStack {
                if let image = item.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                TextField("Description", text: $item.altText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.sentences)
                    .keyboardType(.twitter)
                    .padding()
                    .backportOnChange(of: item.altText) { oldValue, newValue in
                        if newValue.count > maxLength {
                            item.altText = String(newValue.prefix(maxLength))
                        }
                    }
                
                HStack {
                    Spacer()
                    Text("\(item.altText.count)/\(maxLength)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
