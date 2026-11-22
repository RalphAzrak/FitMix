import AVFoundation
import SwiftUI

/// The fallback when live detection misses a garment: the frame is frozen, the user confirms what the
/// garment is and adjusts the crop around it, and Studio opens on that frame exactly as it does after
/// a tap on a live target. See Docs/LiveGarmentMatch.md.
struct ManualGarmentSelectView: View {
    let frame: LiveManualFrame
    var cancel: () -> Void
    var use: (LiveGarmentSelection) -> Void

    @State private var category: GarmentCategory
    /// Normalized to the frame, top-left origin.
    @State private var crop: CGRect
    /// Set once the user moves or resizes the box, so choosing another category doesn't undo it.
    @State private var adjusted = false
    @State private var dragStart: CGRect?
    @State private var failed = false

    static let minSide = 0.06

    init(frame: LiveManualFrame, initialCategory: GarmentCategory? = nil,
         cancel: @escaping () -> Void, use: @escaping (LiveGarmentSelection) -> Void) {
        self.frame = frame
        self.cancel = cancel
        self.use = use
        // Start on the first garment the scanner didn't find: that's most likely the one missing.
        let found = Set(frame.detections.map(\.category))
        let start = initialCategory ?? GarmentCategory.liveScannable.first { !found.contains($0) } ?? .tshirt
        _category = State(initialValue: start)
        _crop = State(initialValue: Self.suggestedCrop(for: start, in: frame))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            photo
            controls
        }
        .background(Color.fmBackground.ignoresSafeArea())
        .preferredColorScheme(.light)
        .alert("This crop can't be used", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make the box a little larger and try again.")
        }
        #if DEBUG
        .task {
            // FM_DEBUG_MANUAL_CONFIRM=1: confirm the suggested crop after a moment, the way a tap does.
            if ProcessInfo.processInfo.environment["FM_DEBUG_MANUAL_CONFIRM"] == "1" {
                try? await Task.sleep(for: .seconds(1.5))
                confirm()
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            CircleIconButton(systemName: "xmark", label: "Back to Camera", action: cancel)
                .accessibilityIdentifier("manualCancel")
            Spacer()
        }
        .overlay {
            Text("Select a Garment")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.fmInk)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    // MARK: Photo and crop box

    private var photo: some View {
        GeometryReader { proxy in
            let size = CGSize(width: frame.image.width, height: frame.image.height)
            let fit = AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: proxy.size))
            let box = CGRect(x: fit.minX + crop.minX * fit.width, y: fit.minY + crop.minY * fit.height,
                             width: crop.width * fit.width, height: crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)
                // Dim everything outside the box.
                Path { path in
                    path.addRect(fit)
                    path.addRoundedRect(in: box, cornerSize: CGSize(width: 10, height: 10))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.fmCobalt, lineWidth: 3)
                    .background(Color.white.opacity(0.001))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .gesture(moveGesture(fit: fit))
                    .accessibilityElement()
                    .accessibilityLabel("Crop around the \(category.title.lowercased())")
                    .accessibilityHint("Use the actions to move or resize the box.")
                    .accessibilityActions { accessibilityAdjustments }
                    .accessibilityIdentifier("manualCropBox")
                ForEach(Corner.allCases, id: \.self) { corner in
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.fmCobalt, lineWidth: 3))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(corner.point(in: box))
                        .gesture(resizeGesture(corner, fit: fit))
                        .accessibilityHidden(true)
                }
                FMTooltip(text: category.title)
                    .position(x: min(max(box.midX, fit.minX + 60), fit.maxX - 60),
                              y: max(box.minY - 24, fit.minY + 20))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
    }

    private func moveGesture(fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                var moved = start.offsetBy(dx: value.translation.width / fit.width, dy: value.translation.height / fit.height)
                moved.origin.x = min(max(0, moved.minX), 1 - moved.width)
                moved.origin.y = min(max(0, moved.minY), 1 - moved.height)
                crop = moved
                adjusted = true
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                crop = corner.resize(start, by: CGSize(width: value.translation.width / fit.width,
                                                       height: value.translation.height / fit.height),
                                     minSide: Self.minSide)
                adjusted = true
            }
            .onEnded { _ in dragStart = nil }
    }

    @ViewBuilder
    private var accessibilityAdjustments: some View {
        Button("Move Up") { nudge(dy: -0.04) }
        Button("Move Down") { nudge(dy: 0.04) }
        Button("Move Left") { nudge(dx: -0.04) }
        Button("Move Right") { nudge(dx: 0.04) }
        Button("Larger") { scale(1.15) }
        Button("Smaller") { scale(1 / 1.15) }
    }

    private func nudge(dx: Double = 0, dy: Double = 0) {
        var moved = crop.offsetBy(dx: dx, dy: dy)
        moved.origin.x = min(max(0, moved.minX), 1 - moved.width)
        moved.origin.y = min(max(0, moved.minY), 1 - moved.height)
        crop = moved
        adjusted = true
    }

    private func scale(_ factor: Double) {
        let w = min(1, max(Self.minSide, crop.width * factor)), h = min(1, max(Self.minSide, crop.height * factor))
        crop = Self.clamped(CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h))
        adjusted = true
    }

    // MARK: Category and confirm

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            FMSectionHeader(title: "What is it?")
            HStack(spacing: 8) {
                ForEach(GarmentCategory.liveScannable, id: \.self) { option in
                    let selected = option == category
                    Button {
                        category = option
                        if !adjusted { crop = Self.suggestedCrop(for: option, in: frame) }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? .white : Color.fmInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(selected ? Color.fmCobalt : Color.fmFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.fmHairline))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("manualCategory-\(option.rawValue)")
                }
            }
            Text("Drag the box over the garment, or drag a corner to resize it.")
                .font(.system(size: 14))
                .foregroundStyle(Color.fmSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use This Crop", action: confirm)
                .buttonStyle(FMFilledButtonStyle())
                .accessibilityIdentifier("manualUse")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.fmBackground)
    }

    private func confirm() {
        guard let selection = Self.selection(category: category, crop: crop, frame: frame) else {
            failed = true
            return
        }
        use(selection)
    }

    // MARK: Building the selection

    /// The same hand-off as a tapped live target: the frozen frame, the chosen garment cut with the box
    /// shown, and any other garments the scanner found in that frame.
    static func selection(category: GarmentCategory, crop: CGRect, frame: LiveManualFrame) -> LiveGarmentSelection? {
        guard let chosen = LiveGarmentSelection.crop(frame.image, to: crop, padding: 0) else { return nil }
        var garments = [LiveGarmentSelection.Garment(category: category, bounds: crop, crop: chosen)]
        for detection in frame.detections where detection.category != category && GarmentCategory.liveScannable.contains(detection.category) {
            guard let image = LiveGarmentSelection.crop(frame.image, to: detection.bounds, padding: 0) else { continue }
            garments.append(LiveGarmentSelection.Garment(category: detection.category, bounds: detection.bounds,
                                                         crop: image, color: detection.color))
        }
        garments.sort { a, b in
            (GarmentCategory.liveScannable.firstIndex(of: a.category) ?? 0) < (GarmentCategory.liveScannable.firstIndex(of: b.category) ?? 0)
        }
        var selection = LiveGarmentSelection(frame: frame.image, capturedAt: frame.date, garments: garments, selected: category)
        selection.isTestPhoto = frame.isTestPhoto
        return selection
    }

    /// Where the box starts: the scanner's own box for that garment if it found one, otherwise the
    /// usual place for it on the person found in the frame, otherwise the usual place in the frame.
    static func suggestedCrop(for category: GarmentCategory, in frame: LiveManualFrame) -> CGRect {
        if let detection = frame.detections.first(where: { $0.category == category }) {
            return clamped(detection.bounds)
        }
        // Fractions of the person's height (pose bounds run from about the nose to the ankles).
        let band: (x: ClosedRange<Double>, y: ClosedRange<Double>) = switch category {
        case .jacket: (-0.15...1.15, 0.1...0.62)
        case .pants: (0.0...1.0, 0.47...1.0)
        case .shoes: (-0.1...1.1, 0.93...1.08)
        default: (0.0...1.0, 0.12...0.55)
        }
        if let person = frame.subjectBounds, person.height > 0.25, person.width > 0.05 {
            return clamped(CGRect(x: person.minX + band.x.lowerBound * person.width,
                                  y: person.minY + band.y.lowerBound * person.height,
                                  width: (band.x.upperBound - band.x.lowerBound) * person.width,
                                  height: (band.y.upperBound - band.y.lowerBound) * person.height))
        }
        return switch category {
        case .jacket: CGRect(x: 0.15, y: 0.18, width: 0.7, height: 0.42)
        case .pants: CGRect(x: 0.25, y: 0.48, width: 0.5, height: 0.42)
        case .shoes: CGRect(x: 0.25, y: 0.78, width: 0.5, height: 0.17)
        default: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.35)
        }
    }

    static func clamped(_ rect: CGRect) -> CGRect {
        let w = min(1, max(minSide, rect.width)), h = min(1, max(minSide, rect.height))
        return CGRect(x: min(max(0, rect.minX), 1 - w), y: min(max(0, rect.minY), 1 - h), width: w, height: h)
    }
}

/// A corner handle of the crop box.
private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// Moves this corner by `delta` (normalized), keeping the opposite corner fixed and the box in frame.
    func resize(_ rect: CGRect, by delta: CGSize, minSide: Double) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch self {
        case .topLeft: minX += delta.width; minY += delta.height
        case .topRight: maxX += delta.width; minY += delta.height
        case .bottomLeft: minX += delta.width; maxY += delta.height
        case .bottomRight: maxX += delta.width; maxY += delta.height
        }
        minX = min(max(0, minX), rect.maxX - minSide)
        maxX = max(min(1, maxX), rect.minX + minSide)
        minY = min(max(0, minY), rect.maxY - minSide)
        maxY = max(min(1, maxY), rect.minY + minSide)
        if self == .topLeft || self == .bottomLeft { maxX = rect.maxX } else { minX = rect.minX }
        if self == .topLeft || self == .topRight { maxY = rect.maxY } else { minY = rect.minY }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
