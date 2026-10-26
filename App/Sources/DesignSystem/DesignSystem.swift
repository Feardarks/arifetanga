import SwiftUI

/// Tasarım sisteminin S0'da gereken en küçük alt kümesi (03-tasarim §6).
/// Arayüz SDR'da kalır; Nit modunda video SDR beyazının katlarına çıktığı için zeminler opaktır.
enum DS {
    // P3 tanımlı durum renkleri (03-tasarim §6); SDR'da kalır, EDR'ye çıkmaz.
    static let amber = Color(.displayP3, red: 1.0, green: 0.72, blue: 0.20)
    static let red = Color(.displayP3, red: 1.0, green: 0.33, blue: 0.30)
    static let green = Color(.displayP3, red: 0.35, green: 0.85, blue: 0.45)
    static let secondary = Color.white.opacity(0.62)
    static let hairline = Color.white.opacity(0.14)
    static let islandRadius: CGFloat = 16
    /// HIG en küçük dokunma hedefi.
    static let minTouch: CGFloat = 44
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
}

/// OLED adacığı: opak siyah zemin, ince kenar çizgisi. Altındaki videoyu karartmaz, yalnızca kendi alanını kaplar.
struct OLEDIsland: ViewModifier {
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.black, in: RoundedRectangle(cornerRadius: DS.islandRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.islandRadius, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }
}

extension View {
    func oledIsland(padding: CGFloat = 10) -> some View {
        modifier(OLEDIsland(padding: padding))
    }
}

/// İki seçenekli segment (C-04 / C-05).
struct SegmentToggle<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var disabled = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .foregroundStyle(selection == option.0 ? Color.black : Color.white)
                        .background(selection == option.0 ? Color.white : Color.clear,
                                    in: Capsule(style: .continuous))
                        .frame(minHeight: DS.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(Capsule(style: .continuous).stroke(DS.hairline, lineWidth: 1))
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}

/// Kapsül biçimli araç düğmesi; açık/kapalı durumu nokta ile gösterilir (C-03).
struct PillButton: View {
    let title: String
    var isOn: Bool?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let isOn {
                    Circle().fill(isOn ? DS.green : Color.white.opacity(0.25)).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .foregroundStyle(Color.white)
            .overlay(Capsule(style: .continuous).stroke(DS.hairline, lineWidth: 1))
            .frame(minHeight: DS.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
    }
}
