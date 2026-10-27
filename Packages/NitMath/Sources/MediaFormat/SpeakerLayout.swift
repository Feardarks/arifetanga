import Foundation

/// Hoparlör konumu; Core Audio kanal etiketlerine birebir karşılık gelir (uygulama `kAudioChannelLabel_*`'a çevirir).
public enum SpeakerPosition: String, Sendable, CaseIterable {
    case left = "L", right = "R", center = "C", lfe = "LFE", lfe2 = "LFE2"
    /// Core Audio Ls/Rs: 5.1'de surround, 7.1'de yan surround.
    case surroundLeft = "Ls", surroundRight = "Rs"
    /// Core Audio Rls/Rrs: 7.1'de arka surround.
    case rearSurroundLeft = "Rls", rearSurroundRight = "Rrs"
    case centerSurround = "Cs"
    case leftCenter = "Lc", rightCenter = "Rc"
    case leftWide = "Lw", rightWide = "Rw"
    case surroundDirectLeft = "Lsd", surroundDirectRight = "Rsd"
    case topCenter = "Ts"
    case topFrontLeft = "Vhl", topFrontCenter = "Vhc", topFrontRight = "Vhr"
    case topMiddleLeft = "Ltm", topMiddleRight = "Rtm"
    case topBackLeft = "Ltr", topBackCenter = "Ctr", topBackRight = "Rtr"
    case leftTotal = "Lt", rightTotal = "Rt"
    case unknown = "?"
}

/// FFmpeg `AVChannel` → hoparlör konumu (02-cozum §5.1: etiket tabanlı eşlemedeki Ls/Rs ↔ Rls/Rrs karışıklığına karşı
/// açık kanal tanımı). FFmpeg'in "5.1"i yan (SL/SR), "5.1(back)"u arka (BL/BR) surround kullanır; Core Audio'da
/// ikisi de Ls/Rs'dir. Yalnızca yan ve arka çift birlikte varsa (7.1) arka çift Rls/Rrs olur.
public enum SpeakerLayout {
    /// `enum AVChannel` değerleri (libavutil/channel_layout.h, FFmpeg 8.0).
    public enum FFChannel {
        public static let frontLeft: Int32 = 0, frontRight: Int32 = 1, frontCenter: Int32 = 2, lowFrequency: Int32 = 3
        public static let backLeft: Int32 = 4, backRight: Int32 = 5
        public static let frontLeftOfCenter: Int32 = 6, frontRightOfCenter: Int32 = 7, backCenter: Int32 = 8
        public static let sideLeft: Int32 = 9, sideRight: Int32 = 10, topCenter: Int32 = 11
        public static let topFrontLeft: Int32 = 12, topFrontCenter: Int32 = 13, topFrontRight: Int32 = 14
        public static let topBackLeft: Int32 = 15, topBackCenter: Int32 = 16, topBackRight: Int32 = 17
        public static let stereoLeft: Int32 = 29, stereoRight: Int32 = 30, wideLeft: Int32 = 31, wideRight: Int32 = 32
        public static let surroundDirectLeft: Int32 = 33, surroundDirectRight: Int32 = 34, lowFrequency2: Int32 = 35
        public static let topSideLeft: Int32 = 36, topSideRight: Int32 = 37
    }

    /// Kanal sırasıyla FFmpeg kanalları → konumlar.
    public static func positions(ffmpegChannels channels: [Int32]) -> [SpeakerPosition] {
        let hasSide = channels.contains(FFChannel.sideLeft) || channels.contains(FFChannel.sideRight)
        return channels.map { c in
            switch c {
            case FFChannel.frontLeft: return .left
            case FFChannel.frontRight: return .right
            case FFChannel.frontCenter: return .center
            case FFChannel.lowFrequency: return .lfe
            case FFChannel.lowFrequency2: return .lfe2
            case FFChannel.sideLeft: return .surroundLeft
            case FFChannel.sideRight: return .surroundRight
            case FFChannel.backLeft: return hasSide ? .rearSurroundLeft : .surroundLeft
            case FFChannel.backRight: return hasSide ? .rearSurroundRight : .surroundRight
            case FFChannel.backCenter: return .centerSurround
            case FFChannel.frontLeftOfCenter: return .leftCenter
            case FFChannel.frontRightOfCenter: return .rightCenter
            case FFChannel.wideLeft: return .leftWide
            case FFChannel.wideRight: return .rightWide
            case FFChannel.surroundDirectLeft: return .surroundDirectLeft
            case FFChannel.surroundDirectRight: return .surroundDirectRight
            case FFChannel.topCenter: return .topCenter
            case FFChannel.topFrontLeft: return .topFrontLeft
            case FFChannel.topFrontCenter: return .topFrontCenter
            case FFChannel.topFrontRight: return .topFrontRight
            case FFChannel.topSideLeft: return .topMiddleLeft
            case FFChannel.topSideRight: return .topMiddleRight
            case FFChannel.topBackLeft: return .topBackLeft
            case FFChannel.topBackCenter: return .topBackCenter
            case FFChannel.topBackRight: return .topBackRight
            case FFChannel.stereoLeft: return .leftTotal
            case FFChannel.stereoRight: return .rightTotal
            default: return .unknown
            }
        }
    }

    /// Bilinen düzen yoksa (FFmpeg "unspecified") kanal sayısından varsayılan: 1 → C, 2 → L R, 6 → 5.1, 8 → 7.1.
    public static func defaultPositions(channelCount n: Int) -> [SpeakerPosition] {
        switch n {
        case 1: return [.center]
        case 2: return [.left, .right]
        case 3: return [.left, .right, .center]
        case 4: return [.left, .right, .surroundLeft, .surroundRight]
        case 5: return [.left, .right, .center, .surroundLeft, .surroundRight]
        case 6: return [.left, .right, .center, .lfe, .surroundLeft, .surroundRight]
        case 7: return [.left, .right, .center, .lfe, .centerSurround, .surroundLeft, .surroundRight]
        case 8: return [.left, .right, .center, .lfe, .rearSurroundLeft, .rearSurroundRight, .surroundLeft, .surroundRight]
        default: return [SpeakerPosition](repeating: .unknown, count: max(n, 0))
        }
    }

    /// "7.1", "5.1", "2.0", "7.1.4" gibi kısa ad: yatay.LFE.tavan.
    public static func name(_ positions: [SpeakerPosition]) -> String {
        let lfe = positions.filter { $0 == .lfe || $0 == .lfe2 }.count
        let top: Set<SpeakerPosition> = [.topCenter, .topFrontLeft, .topFrontCenter, .topFrontRight, .topMiddleLeft,
                                          .topMiddleRight, .topBackLeft, .topBackCenter, .topBackRight]
        let height = positions.filter { top.contains($0) }.count
        let bed = positions.count - lfe - height
        if positions.count == 1 { return "1.0" }
        return height > 0 ? "\(bed).\(lfe).\(height)" : "\(bed).\(lfe)"
    }
}
