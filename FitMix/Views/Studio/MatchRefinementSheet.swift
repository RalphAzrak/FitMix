import SwiftUI

struct MatchRefinementSheet: View {
    let frame: UIImage
    let category: GarmentCategory
    let detectedBounds: CGRect
    let description: String?
    let search: (CGRect, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bounds: CGRect
    @State private var brand: String
    @State private var editCrop = false
    @State private var cropError = false

    init(frame: UIImage, category: GarmentCategory, detectedBounds: CGRect, initialBounds: CGRect, brand: String,
         description: String?, search: @escaping (CGRect, String) -> Bool) {
        self.frame = frame
        self.category = category
        self.detectedBounds = detectedBounds
        self.description = description
        self.search = search
        _bounds = State(initialValue: initialBounds)
        _brand = State(initialValue: brand)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let image = frame.cgImage.flatMap({ LiveGarmentSelection.crop($0, to: bounds, padding: 0) }) {
                        Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .fmHeroFrame().accessibilityLabel("Crop of \(category.title)")
                    }
                    Button("Adjust Crop", systemImage: "crop") { editCrop = true }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    if let description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Visible Details").font(.headline)
                            Text(description).font(.subheadline).foregroundStyle(Color.fmSecondary)
                        }
                    }
                    HStack {
                        TextField("Brand (optional)", text: $brand)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.search)
                            .onSubmit(findSimilar)
                        if !brand.isEmpty {
                            Button("Clear Brand") { brand = "" }
                                .font(.subheadline).frame(minHeight: 44)
                        }
                    }
                    .fmCard(padding: 12)
                    Text("A brand filter shows listings whose retailer confirms that brand.")
                        .font(.footnote).foregroundStyle(Color.fmSecondary)
                    if cropError {
                        NoticeRow(tone: .caution, text: "Include a larger area of the garment or take a closer scan.")
                    }
                }
                .padding(18)
            }
            .background(Color.fmCanvas)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FMActionShelf {
                    Button("Find Similar", systemImage: "magnifyingglass", action: findSimilar)
                        .buttonStyle(FMFilledButtonStyle())
                        .disabled(!validBrand)
                }
            }
            .navigationTitle("Refine \(category.title) Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $editCrop) {
                WardrobeCropView(image: frame, initialCrop: bounds,
                                 hint: "Include the whole visible garment and its details. Keep nearby clothes and faces outside the frame.",
                                 minimumFraction: 0.03, allowedBounds: StudioStore.matchCropLimits(for: detectedBounds),
                                 resetBounds: detectedBounds) { crop in
                    bounds = crop
                    cropError = false
                }
            }
        }
    }

    private var cleanBrand: String { brand.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validBrand: Bool {
        cleanBrand.isEmpty || (cleanBrand.count <= 80 && cleanBrand.contains(where: { $0.isLetter || $0.isNumber }))
    }

    private func findSimilar() {
        guard validBrand else { return }
        if search(bounds, cleanBrand) {
            dismiss()
        } else {
            cropError = true
        }
    }
}
