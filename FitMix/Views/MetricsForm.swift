import SwiftUI

/// Metric / Imperial switch.
struct UnitToggle: View {
    @Binding var units: UnitSystem

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UnitSystem.allCases, id: \.self) { option in
                Button {
                    units = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(units == option ? Color.fmInk : Color.fmSecondary)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                        .background(units == option ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(units == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Height and weight entry. Values are kept in centimetres and kilograms, so switching
/// units only changes how they are shown and never rounds what the user typed.
struct MetricsForm: View {
    @Binding var heightCm: Double?
    @Binding var weightKg: Double?
    @Binding var units: UnitSystem

    @State private var cmText = ""
    @State private var feetText = ""
    @State private var inchesText = ""
    @State private var weightText = ""
    @State private var heightUnreadable = false
    @State private var weightUnreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Units").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.fmInk)
                Spacer()
                UnitToggle(units: $units)
            }

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Height")
                if units == .metric {
                    field(text: typed({ cmText }, { cmText = $0 }, then: readMetricHeight), unit: "cm", label: "Height in centimetres")
                } else {
                    HStack(spacing: 10) {
                        field(text: typed({ feetText }, { feetText = $0 }, then: readImperialHeight), unit: "ft", label: "Height, feet")
                        field(text: typed({ inchesText }, { inchesText = $0 }, then: readImperialHeight), unit: "in", label: "Height, inches")
                    }
                }
                if let message = heightMessage { errorText(message) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Weight")
                field(text: typed({ weightText }, { weightText = $0 }, then: readWeight), unit: units == .metric ? "kg" : "lb",
                      label: units == .metric ? "Weight in kilograms" : "Weight in pounds")
                if let message = weightMessage { errorText(message) }
            }
        }
        .onAppear(perform: showStoredValues)
        .onChange(of: units) { showStoredValues() }
    }

    private var heightMessage: String? {
        heightUnreadable ? "Enter your height as a number." : BodyMeasurements.heightError(cm: heightCm, units: units)
    }

    private var weightMessage: String? {
        weightUnreadable ? "Enter your weight as a number." : BodyMeasurements.weightError(kg: weightKg, units: units)
    }

    private func field(text: Binding<String>, unit: String, label: String) -> some View {
        HStack(spacing: 6) {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.fmInk)
                .accessibilityLabel(label)
            Text(unit).font(.system(size: 15)).foregroundStyle(Color.fmSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(Color.fmTile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.fmHairline))
    }

    private func errorText(_ message: String) -> some View {
        Text(message).font(.system(size: 13)).foregroundStyle(Color.fmError)
    }

    /// Only the user's own typing goes through here, so redisplaying a value in other units never alters it.
    private func typed(_ get: @escaping () -> String, _ set: @escaping (String) -> Void, then read: @escaping () -> Void) -> Binding<String> {
        Binding(get: get, set: { newValue in
            guard newValue != get() else { return }
            set(newValue)
            read()
        })
    }

    private func number(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func readMetricHeight() {
        heightCm = number(cmText)
        heightUnreadable = heightCm == nil && !cmText.isEmpty
    }

    private func readImperialHeight() {
        let inches = inchesText.isEmpty ? 0 : number(inchesText)
        if let feet = number(feetText), let inches, inches < 12 {
            heightCm = BodyMeasurements.cm(feet: feet, inches: inches)
            heightUnreadable = false
        } else {
            heightCm = nil
            heightUnreadable = !(feetText.isEmpty && inchesText.isEmpty)
        }
    }

    private func readWeight() {
        let value = number(weightText)
        weightKg = value.map { units == .metric ? $0 : BodyMeasurements.kg(fromPounds: $0) }
        weightUnreadable = value == nil && !weightText.isEmpty
    }

    private func showStoredValues() {
        heightUnreadable = false
        weightUnreadable = false
        if let cm = heightCm {
            cmText = BodyMeasurements.trimmed(cm)
            let (feet, inches) = BodyMeasurements.feetInches(fromCm: cm)
            feetText = String(feet)
            inchesText = String(inches)
        } else {
            cmText = ""; feetText = ""; inchesText = ""
        }
        if let kg = weightKg {
            weightText = BodyMeasurements.trimmed(units == .metric ? kg : BodyMeasurements.pounds(fromKg: kg))
        } else {
            weightText = ""
        }
    }
}
