import AVFoundation
import Foundation

public struct CameraCapabilities {
    public let supportsFocusPoint: Bool
    public let focusModes: [String]
    public let supportsExposurePoint: Bool
    public let exposureModes: [String]
    public let whiteBalanceModes: [String]
    public let supportsManualWhiteBalanceGains: Bool
    public let supportsManualExposure: Bool
    public let supportsHardwareZoom: Bool
    public let supportsTorch: Bool
    public let supportsMirroring: Bool
    public let supportsRotation: Bool
    public let supportedResolutions: [[String: Int]]
    public let supportedFormats: [[String: Any]]

    public var toMap: [String: Any] {
        return [
            "supportsFocusPoint": supportsFocusPoint,
            "focusModes": focusModes,
            "supportsExposurePoint": supportsExposurePoint,
            "exposureModes": exposureModes,
            "whiteBalanceModes": whiteBalanceModes,
            "supportsManualWhiteBalanceGains": supportsManualWhiteBalanceGains,
            "supportsManualExposure": supportsManualExposure,
            "supportsHardwareZoom": supportsHardwareZoom,
            "supportsTorch": supportsTorch,
            "supportsMirroring": supportsMirroring,
            "supportsRotation": supportsRotation,
            "supportedResolutions": supportedResolutions,
            "supportedFormats": supportedFormats,
        ]
    }
}

public enum CapabilityDiscovery {
    public static func discover(device: AVCaptureDevice,
                                 captureSession: AVCaptureSession?,
                                 previewLayer: AVCaptureVideoPreviewLayer?) -> CameraCapabilities {
        // Focus
        var focusModes: [String] = []
        if device.isFocusModeSupported(.autoFocus) { focusModes.append("auto") }
        if device.isFocusModeSupported(.continuousAutoFocus) { focusModes.append("continuous") }
        if device.isFocusModeSupported(.locked) { focusModes.append("locked") }
        let supportsFocusPoint = device.isFocusPointOfInterestSupported

        // Exposure
        var exposureModes: [String] = []
        if device.isExposureModeSupported(.autoExpose) { exposureModes.append("auto") }
        if device.isExposureModeSupported(.continuousAutoExposure) { exposureModes.append("continuous") }
        if device.isExposureModeSupported(.locked) { exposureModes.append("locked") }
        let supportsExposurePoint = device.isExposurePointOfInterestSupported

        // White balance (modes only)
        var whiteBalanceModes: [String] = []
        if device.isWhiteBalanceModeSupported(.autoWhiteBalance) { whiteBalanceModes.append("auto") }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { whiteBalanceModes.append("continuous") }
        if device.isWhiteBalanceModeSupported(.locked) { whiteBalanceModes.append("locked") }

        // Manual controls unavailable on macOS native
        let supportsManualWhiteBalanceGains = false
        let supportsManualExposure = false
        let supportsHardwareZoom = false

        // Torch
        let supportsTorch = device.hasTorch && (device.isTorchModeSupported(.on) || device.isTorchModeSupported(.auto))

        // Connection-based
        var supportsMirroring = false
        var supportsRotation = false
        if let captureSession = captureSession {
            for output in captureSession.outputs {
                if let connection = output.connection(with: .video) {
                    if connection.isVideoMirroringSupported { supportsMirroring = true }
                    if #available(macOS 14.0, *) {
                        if connection.isVideoRotationAngleSupported(90) { supportsRotation = true }
                    }
                }
            }
        }
        if !supportsMirroring, let connection = previewLayer?.connection {
            if connection.isVideoMirroringSupported { supportsMirroring = true }
            if #available(macOS 14.0, *) {
                if connection.isVideoRotationAngleSupported(90) { supportsRotation = true }
            }
        }

        // Resolutions (unique width x height) and collect distinct fps ranges without merging across formats
        struct FpsKey: Hashable { let w: Int; let h: Int; let min: Double; let max: Double }
        var resolutionsSet = Set<String>()
        var resolutions: [[String: Int]] = []
        var seenFormatKeys = Set<FpsKey>()
        var formats: [[String: Any]] = []
        for format in device.formats {
            let desc = format.formatDescription
            let dim = CMVideoFormatDescriptionGetDimensions(desc)
            let w = Int(dim.width), h = Int(dim.height)
            let resKey = "\(w)x\(h)"
            if !resolutionsSet.contains(resKey) {
                resolutionsSet.insert(resKey)
                resolutions.append(["width": w, "height": h])
            }
            for range in format.videoSupportedFrameRateRanges {
                // Keep original fractional values
                let minF = max(0.1, range.minFrameRate)
                let maxF = max(minF, range.maxFrameRate)
                let key = FpsKey(w: w, h: h, min: minF, max: maxF)
                if seenFormatKeys.contains(key) { continue }
                seenFormatKeys.insert(key)
                formats.append([
                    "width": w,
                    "height": h,
                    "minFps": minF,
                    "maxFps": maxF,
                ])
            }
        }
        // Stable sort formats by area then minFps then maxFps
        formats.sort { a, b in
            let aw = a["width"] as? Int ?? 0, ah = a["height"] as? Int ?? 0
            let bw = b["width"] as? Int ?? 0, bh = b["height"] as? Int ?? 0
            let aArea = aw * ah, bArea = bw * bh
            if aArea == bArea {
                let amin = (a["minFps"] as? Double) ?? 0
                let bmin = (b["minFps"] as? Double) ?? 0
                if amin == bmin {
                    let amax = (a["maxFps"] as? Double) ?? 0
                    let bmax = (b["maxFps"] as? Double) ?? 0
                    if amax == bmax { return aw < bw }
                    return amax < bmax
                }
                return amin < bmin
            }
            return aArea < bArea
        }

        return CameraCapabilities(
            supportsFocusPoint: supportsFocusPoint,
            focusModes: focusModes,
            supportsExposurePoint: supportsExposurePoint,
            exposureModes: exposureModes,
            whiteBalanceModes: whiteBalanceModes,
            supportsManualWhiteBalanceGains: supportsManualWhiteBalanceGains,
            supportsManualExposure: supportsManualExposure,
            supportsHardwareZoom: supportsHardwareZoom,
            supportsTorch: supportsTorch,
            supportsMirroring: supportsMirroring,
            supportsRotation: supportsRotation,
            supportedResolutions: resolutions,
            supportedFormats: formats
        )
    }
}
