import CoreMedia
import Foundation
import NitMath

/// Demux edilmiş akıştan `CMVideoFormatDescription` ve `CMSampleBuffer` üretimi.
enum FormatDescriptions {
    /// - Parameter forReference: Referans yolu (AVSampleBufferDisplayLayer) için. DV varsa `dvh1` + `dvcC/dvvC`
    ///   ile sistemin Dolby Vision işleyişi tetiklenir (AS-1). Nit yolu (VideoToolbox) her zaman yalnızca BL'yi çözer.
    /// - Parameter doviOverride: P7 → P8.1 dönüşümünde yeniden yazılan yapılandırma (S2.3).
    static func make(_ info: VideoStreamInfo, forReference: Bool, doviOverride: DoviConfig? = nil) -> CMVideoFormatDescription? {
        var atoms: [String: Any] = [:]
        let isHEVC = info.codecType == kCMVideoCodecType_HEVC
        atoms[isHEVC ? "hvcC" : "avcC"] = info.configurationRecord

        var codecType = info.codecType
        if forReference, isHEVC, let dovi = doviOverride ?? info.dovi, dovi.profile != 7 || doviOverride != nil {
            atoms[dovi.atomName] = dovi.record
            codecType = kCMVideoCodecType_DolbyVisionHEVC
        }

        var extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms,
            kCMFormatDescriptionExtension_FullRangeVideo as String: info.fullRange,
        ]
        switch info.primaries {
        case .bt2020: extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case .displayP3: extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_P3_D65
        case .bt709: extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        }
        switch info.transfer {
        case .pq: extensions[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: extensions[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        case .sdrGamma: extensions[kCMFormatDescriptionExtension_TransferFunction as String] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        switch info.matrix {
        case .bt2020: extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        case .bt601: extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case .bt709: extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        }
        if info.maxCLL != nil || info.maxFALL != nil {
            let cll = UInt16(min(info.maxCLL ?? 0, 65535))
            let fall = UInt16(min(info.maxFALL ?? 0, 65535))
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] =
                Data([UInt8(cll >> 8), UInt8(cll & 0xFF), UInt8(fall >> 8), UInt8(fall & 0xFF)])
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codecType,
                                                    width: Int32(info.width), height: Int32(info.height),
                                                    extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    static func sampleBuffer(_ packet: DemuxedPacket, format: CMFormatDescription, data: Data? = nil) -> CMSampleBuffer? {
        let bytes = data ?? packet.data
        let length = bytes.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: packet.duration, presentationTimeStamp: packet.pts,
                                        decodeTimeStamp: packet.dts)
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if !packet.keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
