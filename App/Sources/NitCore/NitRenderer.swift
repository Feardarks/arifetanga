import CoreVideo
import Metal
import NitMath
import QuartzCore
import simd

/// Shader'daki `NitUniforms` ile birebir aynı düzen (11 × float4).
struct NitUniforms {
    var yRange = SIMD4<Float>.zero
    var ycc0 = SIMD4<Float>.zero
    var ycc1 = SIMD4<Float>.zero
    var ycc2 = SIMD4<Float>.zero
    var gam0 = SIMD4<Float>.zero
    var gam1 = SIMD4<Float>.zero
    var gam2 = SIMD4<Float>.zero
    var curve = SIMD4<Float>.zero
    var tone = SIMD4<Float>.zero
    var dither = SIMD4<Float>.zero
    var pattern = SIMD4<Float>.zero
    var scaler = SIMD4<Float>.zero
}

enum SourcePrimaries: String {
    case bt709 = "709"
    case bt2020 = "2020"
    case displayP3 = "P3"

    var primaries: ColorPrimaries {
        switch self {
        case .bt709: .bt709
        case .bt2020: .bt2020
        case .displayP3: .displayP3
        }
    }
}

/// Bir video karesinin renk biçimi; piksel tamponunun eklerinden okunur.
struct FrameFormat: Equatable {
    var bitDepth: Int
    var fullRange: Bool
    var matrix: YCbCrMatrix
    var primaries: SourcePrimaries
    var transfer: TransferFunction

    var label: String {
        let tf: String
        switch transfer {
        case .sdrGamma: tf = "SDR"
        case .pq: tf = "PQ"
        case .hlg: tf = "HLG"
        }
        return "\(bitDepth)-bit · \(tf) · \(primaries.rawValue)\(fullRange ? " · tam aralık" : "")"
    }

    static func from(_ pb: CVPixelBuffer, hdrHint: Bool) -> FrameFormat {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let tenBit = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let att = (CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any]) ?? [:]

        func value(_ key: CFString) -> String? { att[key as String] as? String }
        func matches(_ key: CFString, _ expected: CFString) -> Bool { value(key) == (expected as String) }

        let matrix: YCbCrMatrix
        if matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            matrix = .bt2020
        } else if matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            matrix = .bt601
        } else if matches(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            matrix = .bt709
        } else {
            matrix = hdrHint ? .bt2020 : .bt709
        }

        let primaries: SourcePrimaries
        if matches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020) {
            primaries = .bt2020
        } else if matches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65) {
            primaries = .displayP3
        } else if matches(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2) {
            primaries = .bt709
        } else {
            primaries = hdrHint ? .bt2020 : .bt709
        }

        let transfer: TransferFunction
        if matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) {
            transfer = .pq
        } else if matches(kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            transfer = .hlg
        } else if value(kCVImageBufferTransferFunctionKey) != nil {
            transfer = .sdrGamma
        } else {
            transfer = hdrHint ? .pq : .sdrGamma
        }

        return FrameFormat(bitDepth: tenBit ? 10 : 8, fullRange: full, matrix: matrix, primaries: primaries, transfer: transfer)
    }
}

/// Bir karenin nasıl çizileceğini belirleyen ayarlar.
struct RenderSettings: Equatable {
    var curve: NitCurve
    var sdrGamma: Double
    var referenceWhiteNits: Double
    var dither: Bool
    var ditherBits: Int
    /// Kaliteli ölçekleyici: büyütmede bicubic, küçültmede 2×2 süper örnekleme. Kapalıysa bilineer.
    var highQualityScaler: Bool
}

/// Son N karenin GPU süreleri; Metal tamamlanma işleyicisinden (başka thread) yazılır.
final class GPUStats: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private let capacity = 240

    func add(_ ms: Double) {
        lock.lock()
        samples.append(ms)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lock.unlock()
    }

    /// (p50, p95) milisaniye.
    func percentiles() -> (Double, Double) {
        lock.lock()
        let sorted = samples.sorted()
        lock.unlock()
        guard !sorted.isEmpty else { return (0, 0) }
        func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))] }
        return (p(0.50), p(0.95))
    }

    func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

/// Sahne beyazı histogramları: Metal tamamlanma işleyicisinden yazılır, motor her vsync'te en sonuncuyu alır.
final class HistogramStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (bins: [UInt32], pts: Double)?

    func put(_ bins: [UInt32], pts: Double) {
        lock.lock()
        latest = (bins, pts)
        lock.unlock()
    }

    func take() -> (bins: [UInt32], pts: Double)? {
        lock.lock()
        defer { latest = nil; lock.unlock() }
        return latest
    }
}

/// Nit Çekirdeği: Y'CbCr kareyi (ya da deseni) EDR'li `CAMetalLayer`'a çizer.
final class NitRenderer {
    let device: MTLDevice
    let gpuStats = GPUStats()
    let histograms = HistogramStore()
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let histogramPipeline: MTLComputePipelineState
    private let histogramBuffers: [MTLBuffer]
    private var histogramIndex = 0
    private let textureCache: CVMetalTextureCache
    private let dummyLuma: MTLTexture
    private let dummyChroma: MTLTexture
    private var frameIndex: UInt32 = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "nitVertex")
        desc.fragmentFunction = library.makeFunction(name: "nitFragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc),
              let histogramFunction = library.makeFunction(name: "nitHistogram"),
              let histogramPipeline = try? device.makeComputePipelineState(function: histogramFunction) else { return nil }
        let histogramBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        }
        guard histogramBuffers.count == 3 else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

        func dummy(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            return device.makeTexture(descriptor: d)
        }
        guard let dl = dummy(.r8Unorm), let dc = dummy(.rg8Unorm) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.histogramPipeline = histogramPipeline
        self.histogramBuffers = histogramBuffers
        self.textureCache = cache
        self.dummyLuma = dl
        self.dummyChroma = dc
    }

    static func configure(_ layer: CAMetalLayer, device: MTLDevice) {
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Eşitlik testinin Referans yaması için katman: PQ renk uzayı + HDR10 meta verisi.
    /// Ton eşlemeyi sistem yapar; Apple'ın kendi HDR beyazı bununla ölçülür (AS-26, K2).
    static func configureReference(_ layer: CAMetalLayer, device: MTLDevice, maxNits: Double) {
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        layer.wantsExtendedDynamicRangeContent = true
        layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.0001, maxLuminance: Float(maxNits), opticalOutputScale: 100)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Referans yamasını çizer: PQ kodu doğrudan yazılır.
    func renderReferencePatch(layer: CAMetalLayer, windowFraction: Double, centerX: Double, nits: Double) {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(dummyLuma, index: 0)
        encoder.setFragmentTexture(dummyChroma, index: 1)
        var u = NitUniforms()
        u.pattern = SIMD4(Float(PatternKind.pqReference.rawValue), Float(windowFraction), Float(PQ.inverseEOTF(nits)), Float(centerX))
        encoder.setFragmentBytes(&u, length: MemoryLayout<NitUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Bir kare çizer. `pattern` verilirse piksel tamponu yok sayılır.
    /// - Returns: Bu karede çıkışın ulaşabileceği en yüksek EDR değeri (analitik; P-2 denetimi için).
    @discardableResult
    func render(layer: CAMetalLayer,
                pixelBuffer: CVPixelBuffer?,
                format: FrameFormat?,
                pattern: PatternSpec?,
                settings: RenderSettings,
                headroom: Double,
                presentAt: CFTimeInterval? = nil,
                histogramPTS: Double? = nil) -> Double {
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = queue.makeCommandBuffer() else { return 0 }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return 0 }
        encoder.setRenderPipelineState(pipeline)

        var u = NitUniforms()
        var keepAlive: [CVMetalTexture] = []
        var histogramGrid: MTLSize?
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        var isHDR = false

        if let pattern {
            encoder.setFragmentTexture(dummyLuma, index: 0)
            encoder.setFragmentTexture(dummyChroma, index: 1)
            u.pattern = SIMD4(Float(pattern.kind.rawValue), Float(pattern.windowFraction), Float(pattern.levelNits), Float(pattern.centerX))
            isHDR = pattern.kind.isHDR
            // Desenler doğrusal P3'e doğrudan yazılır: SDR desenleri 709, PQ desenleri 2020 primerli kabul edilir.
            setGamut(&u, from: isHDR ? .bt2020 : .bt709)
            u.tone = SIMD4(Float(headroom), isHDR ? 1 : 0, Float(settings.sdrGamma), Float(1 / settings.referenceWhiteNits))
        } else if let pixelBuffer, let format,
                  let (luma, chroma) = makeTextures(pixelBuffer, tenBit: format.bitDepth == 10) {
            keepAlive = [luma, chroma]
            encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
            let sourceWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
            let viewport = aspectFitViewport(content: CGSize(width: sourceWidth, height: Double(CVPixelBufferGetHeight(pixelBuffer))),
                                             in: drawableSize)
            encoder.setViewport(viewport)
            // Histogram, ekrandaki video alanının 1/4 çözünürlüğünde (02-cozum §3.5.1).
            histogramGrid = MTLSize(width: max(Int(viewport.width / 4), 1), height: max(Int(viewport.height / 4), 1), depth: 1)
            u.scaler = SIMD4(settings.highQualityScaler ? 1 : 0, Float(viewport.width / max(sourceWidth, 1)),
                             Float(1 / max(viewport.width, 1)), Float(1 / max(viewport.height, 1)))
            let storage = format.bitDepth == 10 ? 65535.0 / 64.0 : 255.0
            let range = YCbCrRange.make(bitDepth: format.bitDepth, fullRange: format.fullRange, storageScale: storage)
            u.yRange = SIMD4(Float(range.yOffset), Float(range.yScale), Float(range.cOffset), Float(range.cScale))
            let m = format.matrix.toRGB
            u.ycc0 = SIMD4(SIMD3<Float>(m.rows[0]), 0)
            u.ycc1 = SIMD4(SIMD3<Float>(m.rows[1]), 0)
            u.ycc2 = SIMD4(SIMD3<Float>(m.rows[2]), 0)
            setGamut(&u, from: format.primaries)
            isHDR = format.transfer.isHDR
            u.tone = SIMD4(Float(headroom), Float(format.transfer.rawValue), Float(settings.sdrGamma), Float(1 / settings.referenceWhiteNits))
        } else {
            // Gösterilecek bir şey yok: siyah temizle ve sun.
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return 0
        }

        let c = settings.curve.shaderParams
        u.curve = SIMD4(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
        frameIndex &+= 1
        u.dither = SIMD4(settings.dither ? 1 : 0, Float(pow(2.0, -Double(settings.ditherBits))), Float(frameIndex % 64) * 7.13, 0)

        encoder.setFragmentBytes(&u, length: MemoryLayout<NitUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Sahne beyazı histogramı: yalnızca istenen (yeni HDR) karelerde, aynı komut tamponunda.
        var histogramBuffer: MTLBuffer?
        if let histogramPTS, let grid = histogramGrid, isHDR, keepAlive.count == 2,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            let buffer = histogramBuffers[histogramIndex]
            histogramIndex = (histogramIndex + 1) % histogramBuffers.count
            blit.fill(buffer: buffer, range: 0..<buffer.length, value: 0)
            blit.endEncoding()
            if let compute = commandBuffer.makeComputeCommandEncoder() {
                compute.setComputePipelineState(histogramPipeline)
                compute.setTexture(CVMetalTextureGetTexture(keepAlive[0]), index: 0)
                compute.setTexture(CVMetalTextureGetTexture(keepAlive[1]), index: 1)
                compute.setBytes(&u, length: MemoryLayout<NitUniforms>.stride, index: 0)
                compute.setBuffer(buffer, offset: 0, index: 1)
                compute.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                compute.endEncoding()
                histogramBuffer = buffer
            }
        }

        // Hedef vsync'e hizalı sunum (02-cozum §3.8).
        if let presentAt {
            commandBuffer.present(drawable, atTime: presentAt)
        } else {
            commandBuffer.present(drawable)
        }

        let stats = gpuStats
        let textures = keepAlive
        let store = histograms
        let pts = histogramPTS ?? 0
        let completedHistogram = histogramBuffer
        commandBuffer.addCompletedHandler { cb in
            _ = textures
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { stats.add(ms) }
            if let completedHistogram {
                let bins = completedHistogram.contents().bindMemory(to: UInt32.self, capacity: 256)
                store.put(Array(UnsafeBufferPointer(start: bins, count: 256)), pts: pts)
            }
        }
        commandBuffer.commit()

        // SDR'da beyaz tam H'ye çıkar; HDR'da eğri 1'e yalnızca asimptotik yaklaşır.
        return isHDR ? headroom * settings.curve(1e4 / settings.referenceWhiteNits) : headroom
    }

    func flushCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func setGamut(_ u: inout NitUniforms, from primaries: SourcePrimaries) {
        let g = primaries.primaries.conversion(to: .displayP3)
        u.gam0 = SIMD4(SIMD3<Float>(g.rows[0]), 0)
        u.gam1 = SIMD4(SIMD3<Float>(g.rows[1]), 0)
        u.gam2 = SIMD4(SIMD3<Float>(g.rows[2]), 0)
    }

    private func makeTextures(_ pb: CVPixelBuffer, tenBit: Bool) -> (CVMetalTexture, CVMetalTexture)? {
        func plane(_ index: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var tex: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(pb, index)
            let h = CVPixelBufferGetHeightOfPlane(pb, index)
            let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pb, nil, format, w, h, index, &tex)
            return status == kCVReturnSuccess ? tex : nil
        }
        guard CVPixelBufferGetPlaneCount(pb) == 2,
              let y = plane(0, tenBit ? .r16Unorm : .r8Unorm),
              let c = plane(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
        return (y, c)
    }

    private func aspectFitViewport(content: CGSize, in bounds: CGSize) -> MTLViewport {
        guard content.width > 0, content.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: Double(bounds.width), height: Double(bounds.height), znear: 0, zfar: 1)
        }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let w = (content.width * scale).rounded()
        let h = (content.height * scale).rounded()
        return MTLViewport(originX: Double((bounds.width - w) / 2).rounded(), originY: Double((bounds.height - h) / 2).rounded(),
                           width: Double(w), height: Double(h), znear: 0, zfar: 1)
    }
}
