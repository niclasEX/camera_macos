import AVFoundation
import Accelerate.vImage
import Accelerate.vecLib
import Cocoa
import CoreImage.CIContext
import CoreVideo.CVPixelBuffer
import FlutterMacOS

public class CameraMacosPlugin: NSObject, FlutterPlugin {
    let registry: FlutterTextureRegistry
    let registrar: FlutterPluginRegistrar!
    let outputChannel: FlutterMethodChannel!
    var factory: CameraMacOSNativeFactory!

    private var deviceIdToCameraInstance: [String: CameraInstance] = [:]

    init(
        _ registry: FlutterTextureRegistry,
        _ outputChannel: FlutterMethodChannel,
        _ registrar: FlutterPluginRegistrar
    ) {
        self.registry = registry
        self.outputChannel = outputChannel
        self.registrar = registrar
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let inputChannel = FlutterMethodChannel(
            name: "camera_macos",
            binaryMessenger: registrar.messenger
        )
        let outputChannel = FlutterMethodChannel(
            name: "camera_macos",
            binaryMessenger: registrar.messenger
        )
        let instance = CameraMacosPlugin(
            registrar.textures,
            outputChannel,
            registrar
        )
        registrar.addMethodCallDelegate(instance, channel: inputChannel)
        let factory = CameraMacOSNativeFactory(messenger: registrar.messenger)
        registrar.register(factory, withId: "camera_macos_view")
        instance.factory = factory
    }

    public func handle(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult
    ) {
        print(call.method, call.arguments ?? "")
        switch call.method {
        case "listDevices":
            let arguments = call.arguments as? [String: Any] ?? [:]
            listDevices(arguments, result)
        case "getCapabilities":
            guard let arguments = call.arguments as? [String: Any],
                  let deviceId = arguments["deviceId"] as? String else {
                result(FlutterError(code: "MISSING_DEVICE_ID", message: "Missing deviceId", details: nil).toMap)
                return
            }
            if let cameraInstance = deviceIdToCameraInstance[deviceId],
               let device = cameraInstance.videoDevice {
                let caps = CapabilityDiscovery.discover(device: device,
                                                        captureSession: cameraInstance.captureSession,
                                                        previewLayer: cameraInstance.previewLayer)
                result(caps.toMap)
                return
            }
            // Fallback: find device by uniqueID without initializing a session
            let allVideoDevices: [AVCaptureDevice]
            if #available(macOS 10.15, *) {
                allVideoDevices = AVCaptureDevice.captureDevices(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video)
            } else {
                allVideoDevices = AVCaptureDevice.captureDevices(mediaType: .video)
            }
            if let device = allVideoDevices.first(where: { $0.uniqueID == deviceId }) {
                let caps = CapabilityDiscovery.discover(device: device, captureSession: nil, previewLayer: nil)
                result(caps.toMap)
            } else {
                result(FlutterError(code: "CAMERA_NOT_FOUND", message: "No device found for id", details: ["deviceId": deviceId]).toMap)
            }
        case "initialize":
            guard
                let arguments = call.arguments as? [String: Any],
                let deviceId = arguments["deviceId"] as? String,
                !deviceId.isEmpty
            else {
                result(
                    FlutterError(
                        code: "MISSING_DEVICE_ID",
                        message: "No deviceId provided or arguments are missing/invalid",
                        details: nil
                    ).toMap
                )
                return
            }
            
            if let existingInstance = deviceIdToCameraInstance[deviceId] {
                existingInstance.destroy {
                    self.createCameraInstance(arguments, deviceId, result)
                }
            } else {
                createCameraInstance(arguments, deviceId, result)
            }
        case "destroy":
            guard let arguments = call.arguments as? [String: Any],
                let deviceId = arguments["deviceId"] as? String,
                let cameraInstance = deviceIdToCameraInstance[deviceId]
            else {
                result(
                    FlutterError(
                        code: "CAMERA_NOT_FOUND",
                        message: "Camera instance not found",
                        details: nil
                    ).toMap
                )
                return
            }
            cameraInstance.destroy {
                self.deviceIdToCameraInstance.removeValue(forKey: deviceId)
                result(true)
            }
        case "takePicture", "toggleTorch", "startRecording", "stopRecording",
            "setZoom", "setOrientation", "setVideoMirrored", "setFocusPoint", "setResolution", "setBrightness", "setWhiteBalance", "setExposure", "setGain", "setFormat", "setPreviewConfig":
            guard let arguments = call.arguments as? [String: Any],
                let deviceId = arguments["deviceId"] as? String,
                let cameraInstance = deviceIdToCameraInstance[deviceId]
            else {
                result(
                    FlutterError(
                        code: "CAMERA_NOT_FOUND",
                        message: "Camera instance not found",
                        details: nil
                    ).toMap
                )
                return
            }

            switch call.method {
            case "takePicture":
                cameraInstance.takePicture(result)
            case "toggleTorch":
                cameraInstance.toggleTorch(arguments, result)
            case "startRecording":
                cameraInstance.startRecording(arguments, result)
            case "stopRecording":
                cameraInstance.stopRecording(result)
            case "setZoom":
                let requested = arguments["zoom"] as? Double ?? 1.0
                // macOS AVFoundation does not expose hardware zoomFactor controls like iOS.
                // We fallback to digital zoom implemented in image processing pipeline via cameraInstance.zoomLevel.
                cameraInstance.zoomLevel = max(1.0, requested)
                cameraInstance.appliedHardwareZoom = 1.0
                result(nil)
            case "setOrientation":
                cameraInstance.orientation =
                    arguments["orientation"] as? Double ?? 0
                result(nil)
            case "setVideoMirrored":
                cameraInstance.isVideoMirrored =
                    arguments["isVideoMirrored"] as? Bool ?? true
                // Apply the updated mirroring flag immediately to all current video connections
                if let captureSession = cameraInstance.captureSession {
                    for output in captureSession.outputs {
                        for connection in output.connections {
                            if connection.isVideoMirroringSupported {
                                // Disable auto so our manual setting sticks across frames
                                if connection.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                                    connection.automaticallyAdjustsVideoMirroring = false
                                }
                                connection.isVideoMirrored = cameraInstance.isVideoMirrored
                            }
                        }
                    }
                }
                // Also update preview layer connection if present
                if let previewLayer = cameraInstance.previewLayer,
                   let connection = previewLayer.connection,
                   connection.isVideoMirroringSupported {
                    if connection.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                        connection.automaticallyAdjustsVideoMirroring = false
                    }
                    connection.isVideoMirrored = cameraInstance.isVideoMirrored
                }
                result(nil)
            case "setResolution":
                // Repurposed: select closest hardware format preset (legacy alias for setFormat by name)
                guard let resolution = arguments["resolution"] as? String,
                      let device = cameraInstance.videoDevice,
                      let session = cameraInstance.captureSession else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing resolution/device", details: nil).toMap)
                    return
                }
                let target: (w: Int, h: Int) = {
                    switch resolution {
                    case "low": return (640,480)
                    case "medium": return (960,540)
                    case "high": return (1280,720)
                    case "veryHigh": return (1920,1080)
                    case "ultraHigh": return (3840,2160)
                    default: return (1280,720)
                    }
                }()
                do {
                    try device.lockForConfiguration()
                    var best: AVCaptureDevice.Format? = nil
                    var bestDelta = Int.max
                    for f in device.formats {
                        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                        let delta = abs(Int(d.width) - target.w) + abs(Int(d.height) - target.h)
                        if delta < bestDelta { best = f; bestDelta = delta }
                    }
                    if let best = best { device.activeFormat = best }
                    device.unlockForConfiguration()
                    session.beginConfiguration(); session.commitConfiguration()
                    result(nil)
                } catch {
                    result(FlutterError(code: "SET_RESOLUTION_ERROR", message: error.localizedDescription, details: nil).toMap)
                }
            case "setFormat":
                guard let width = arguments["width"] as? Int,
                      let height = arguments["height"] as? Int else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing width/height", details: nil).toMap)
                    return
                }
                let fps = arguments["fps"] as? Double
                if let device = cameraInstance.videoDevice, let session = cameraInstance.captureSession {
                    do {
                        try device.lockForConfiguration()
                        // Find best matching format by resolution
                        var best: AVCaptureDevice.Format? = nil
                        var bestDelta = Int.max
                        for f in device.formats {
                            let desc = f.formatDescription
                            let dim = CMVideoFormatDescriptionGetDimensions(desc)
                            let delta = abs(Int(dim.width) - width) + abs(Int(dim.height) - height)
                            if delta < bestDelta { best = f; bestDelta = delta }
                        }
                        if let best = best {
                            device.activeFormat = best
                            if let fps = fps {
                                let ranges = best.videoSupportedFrameRateRanges
                                if let chosen = ranges.min(by: { (a, b) -> Bool in
                                    let aContains = fps >= a.minFrameRate && fps <= a.maxFrameRate
                                    let bContains = fps >= b.minFrameRate && fps <= b.maxFrameRate
                                    if aContains != bContains { return aContains }
                                    let aCenter = (a.minFrameRate + a.maxFrameRate) / 2.0
                                    let bCenter = (b.minFrameRate + b.maxFrameRate) / 2.0
                                    return abs(aCenter - fps) < abs(bCenter - fps)
                                }) {
                                    // Choose min or max duration closest to desired fps
                                    let minDiff = abs(chosen.minFrameRate - fps)
                                    let maxDiff = abs(chosen.maxFrameRate - fps)
                                    let duration: CMTime = (minDiff <= maxDiff) ? chosen.minFrameDuration : chosen.maxFrameDuration
                                    device.activeVideoMinFrameDuration = duration
                                    device.activeVideoMaxFrameDuration = duration
                                }
                            }
                        }
                        device.unlockForConfiguration()
                        // Commit to ensure preview layer picks changes
                        session.beginConfiguration()
                        session.commitConfiguration()
                        result(nil)
                    } catch {
                        result(FlutterError(code: "SET_FORMAT_ERROR", message: error.localizedDescription, details: nil).toMap)
                    }
                } else {
                    result(FlutterError(code: "DEVICE_NOT_AVAILABLE", message: "Video device unavailable", details: nil).toMap)
                }
            case "setFocusPoint":
                cameraInstance.setFocusPoint(arguments, result)
            case "setBrightness":
                guard arguments["brightness"] as? Double != nil else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing brightness", details: nil).toMap)
                    return
                }
                // Fine-grained exposureTargetBias API is unavailable on macOS. Treat as no-op.
                result(nil)
            case "setWhiteBalance":
                // Validate presence of temperature input, but macOS path does not use it directly
                guard arguments["temperature"] as? Double != nil else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing temperature", details: nil).toMap)
                    return
                }
                if let device = cameraInstance.videoDevice {
                    do {
                        try device.lockForConfiguration()
                        // NOTE: Direct manual white balance gain control APIs (maxWhiteBalanceGain, WhiteBalanceGains, setWhiteBalanceModeLocked) are iOS only and not available on macOS.
                        // For macOS we approximate by switching between predefined temperature presets when supported.
                        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                            device.whiteBalanceMode = .continuousAutoWhiteBalance
                        }
                        // Map temperature roughly to bias via exposure target bias as a fallback (not truly white balance but slight color shift is not directly exposed on macOS AVFoundation).
                        // We keep it a no-op beyond setting auto WB so build succeeds.
                        device.unlockForConfiguration()
                        result(nil)
                    } catch {
                        result(FlutterError(code: "SET_WHITE_BALANCE_ERROR", message: error.localizedDescription, details: nil).toMap)
                    }
                } else {
                    result(FlutterError(code: "DEVICE_NOT_AVAILABLE", message: "Video device unavailable", details: nil).toMap)
                }
            case "setExposure":
                // Many fine-grained exposure APIs (minExposureDuration, maxExposureDuration, iso, setExposureModeCustom) are iOS-only. Provide graceful fallback.
                if let device = cameraInstance.videoDevice {
                    do {
                        try device.lockForConfiguration()
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        device.unlockForConfiguration()
                        result(nil)
                    } catch {
                        result(FlutterError(code: "SET_EXPOSURE_ERROR", message: error.localizedDescription, details: nil).toMap)
                    }
                } else {
                    result(FlutterError(code: "DEVICE_NOT_AVAILABLE", message: "Video device unavailable", details: nil).toMap)
                }
            case "setGain":
                // Gain control via ISO not available on macOS same way; treat as no-op.
                result(nil)
            case "setPreviewConfig":
                // Configure preview-specific options that don't affect recording pipeline
                // Arguments: previewMaxFps (Double?), downscaleFactor (Double?)
                let maxFps = arguments["previewMaxFps"] as? Double
                let downscale = arguments["downscaleFactor"] as? Double
                if let v = maxFps, v > 0 {
                    cameraInstance.previewMaxFPS = v
                } else {
                    cameraInstance.previewMaxFPS = nil
                }
                if let ds = downscale, ds > 0.1, ds <= 1.0 {
                    cameraInstance.previewDownscale = ds
                } else if downscale != nil {
                    // if explicitly set but invalid or 0, disable
                    cameraInstance.previewDownscale = nil
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // This function lists all available devices and returns them to Flutter
    func listDevices(
        _ arguments: [String: Any],
        _ result: @escaping FlutterResult
    ) {
        requestPermission { granted in
            if granted {
                var mediaType: AVMediaType = .video
                if let deviceType = arguments["deviceType"] as? Int {
                    switch deviceType {
                    case 0:  // video
                        mediaType = .video
                    case 1:  // audio
                        mediaType = .audio
                    default:
                        break
                    }
                }
                let devices: [AVCaptureDevice] = AVCaptureDevice.captureDevices(
                    mediaType: mediaType
                )
                var devicesList: [[String: Any]] = []
                for device in devices {
                    devicesList.append([
                        "deviceType": mediaType == .video ? 0 : 1,
                        "localizedName": device.localizedName,
                        "manufacturer": device.manufacturer,
                        "deviceId": device.uniqueID,
                    ])
                }
                result([
                    "devices": devicesList
                ])
            } else {
                result(
                    FlutterError(
                        code: "CAMERA_INITIALIZATION_ERROR",
                        message: "Permission not granted",
                        details: nil
                    ).toFlutterResult
                )
            }
        }
    }

    // Helper method to create and initialize a camera instance
    private func createCameraInstance(
        _ arguments: [String: Any],
        _ deviceId: String,
        _ result: @escaping FlutterResult
    ) {
        // Create a device-specific image stream handler with a stable channel name
        // Using deviceId directly in the channel name can cause issues if it contains special characters
        let cameraInstance = CameraInstance(
            registry: registry,
            outputChannel: outputChannel,
            registrar: registrar,
            factory: factory,
        )

        deviceIdToCameraInstance[deviceId] = cameraInstance
        cameraInstance.initCamera(arguments, result)
    }

    func requestPermission(completionHandler: @escaping (Bool) -> Void) {
        if #available(macOS 10.14, *) {
            AVCaptureDevice.requestAccess(
                for: .video,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(false)
        }
    }
}

// Camera instance class that encapsulates individual camera functionality
class CameraInstance: NSObject, FlutterTexture,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVAssetWriterDelegate,
    AVCaptureFileOutputRecordingDelegate
{
    let registry: FlutterTextureRegistry
    let registrar: FlutterPluginRegistrar!
    let outputChannel: FlutterMethodChannel
    var imageStreamHandler: ImageStreamHandler?

    // Texture id of the camera preview
    var textureId: Int64!

    // Capture session of the camera
    var captureSession: AVCaptureSession!

    // The selected camera
    var videoDevice: AVCaptureDevice!

    // The selected microphone
    var audioDevice: AVCaptureDevice?

    // Image to be sent to the texture
    var latestBuffer: CVImageBuffer!

    // The asset writer to write a file on disk
    var videoWriter: AVAssetWriter!

    // Temp variabile to store FlutterResult methods
    var videoOutputFileURL: URL!

    // Enable Audio
    var enableAudio: Bool = true

    // Video quality
    var videoOutputWidth: Int32!
    var videoOutputHeight: Int32!

    // Semaphore variable
    var isTakingPicture: Bool = false
    var isRecording: Bool = false
    var i: Int = 0
    var videoOutputQueue: DispatchQueue!
    var isDestroyed = false

    // Alternate Movie File Output
    var cameraView: NSView!
    var useMovieFileOutput: Bool!
    var savedResult: FlutterResult!
    var factory: CameraMacOSNativeFactory!
    var previewLayer: AVCaptureVideoPreviewLayer!

    var pictureFormat: NSBitmapImageRep.FileType? = NSBitmapImageRep.FileType
        .tiff
    var videoFormat: AVFileType = .mp4
    var vstring: String = "mp4"

    // Removed software scaling & settings assistant; hardware format now sole source of resolution.

    var audioQuality: AVAudioQuality = .max
    var audioFormat: AudioFormatID = kAudioFormatAppleLossless

    var zoomLevel: Double = 1.0
    // Hardware zoom factor applied directly (AVCaptureDevice.videoZoomFactor)
    var appliedHardwareZoom: CGFloat = 1.0
    var zoomPixelBuffer: CVImageBuffer?
    // Base image size used for digital zoom crop computations
    var zoomBaseSize: CGSize? = nil

    var orientation: CGFloat = 0

    var isVideoMirrored: Bool = true

    // Preview-only controls (do not affect recording):
    // - previewMaxFPS: limit how often we push frames to Flutter texture.
    // - previewDownscale: scale factor (0.1..1.0) applied to preview image before sending to texture.
    // These reduce UI/GPU pressure while keeping sensor/recording at full quality.
    var previewMaxFPS: Double? = nil
    var previewDownscale: Double? = nil
    private var lastPreviewFrameTime: CFTimeInterval = 0

    init(
        registry: FlutterTextureRegistry,
        outputChannel: FlutterMethodChannel,
        registrar: FlutterPluginRegistrar,
        factory: CameraMacOSNativeFactory
    ) {
        self.registry = registry
        self.registrar = registrar
        self.outputChannel = outputChannel
        self.factory = factory

        super.init()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        if latestBuffer == nil {
            return nil
        }
        let u = imageFromSampleBuffer(imageBuffer: latestBuffer)!
        let bytesPerRow = u.bytesPerRow
        let width = Int(u.size.width)
        let height = Int(u.size.height)

        DispatchQueue.main.async {
            do {
                let newData = Data(
                    bytes: u.bitmapData!,
                    count: Int(bytesPerRow * height)
                )

                try self.imageStreamHandler?.success(
                    [
                        "width": width,
                        "height": height,
                        "bytesPerRow": bytesPerRow,
                        "data": newData,
                    ] as [String: Any]
                )
            } catch let err {
                self.imageStreamHandler?.error(
                    code: "IMAGE_STREAM_ERROR",
                    message: err.localizedDescription
                )
            }
        }

        return Unmanaged<CVPixelBuffer>.passRetained(latestBuffer)
    }

    func initCamera(
        _ arguments: [String: Any],
        _ result: @escaping FlutterResult
    ) {
        if let captureSession = captureSession, captureSession.isRunning {
            captureSession.stopRunning()
        }

        requestPermission { granted in
            if granted {
                self.isDestroyed = false
                let textureId = self.registry.register(self)
                self.textureId = textureId

                let streamChannelName = "camera_macos/stream/\(textureId)"
                let imageStreamHandler = ImageStreamHandler(
                    id: streamChannelName,
                    messenger: self.registrar.messenger,
                )
                self.imageStreamHandler = imageStreamHandler

                self.captureSession = AVCaptureSession()
                self.captureSession.beginConfiguration()
                var sessionPresetSet = false
                if let sessionPresetArg = arguments["type"] as? Int {
                    switch sessionPresetArg {
                    case 0:
                        if self.captureSession.canSetSessionPreset(.photo) {
                            sessionPresetSet = true
                            self.captureSession.sessionPreset = .photo
                        }
                    case 1:
                        if self.captureSession.canSetSessionPreset(.high) {
                            sessionPresetSet = true
                            self.captureSession.sessionPreset = .high
                        }
                    default:
                        if self.captureSession.canSetSessionPreset(.photo) {
                            sessionPresetSet = true
                            self.captureSession.sessionPreset = .photo
                        }
                    }
                }

                guard sessionPresetSet else {
                    result(
                        FlutterError(
                            code: "CAMERA_INITIALIZATION_ERROR",
                            message:
                                "Could not set sessionPreset for this device",
                            details: nil
                        ).toFlutterResult
                    )
                    return
                }

                var newCameraObject: AVCaptureDevice!
                var capturedVideoDevices: [AVCaptureDevice] = []

                if #available(macOS 10.15, *) {
                    capturedVideoDevices = AVCaptureDevice.captureDevices(
                        deviceTypes: [
                            .builtInWideAngleCamera, .externalUnknown,
                        ],
                        mediaType: .video
                    )
                } else {
                    capturedVideoDevices = AVCaptureDevice.captureDevices(
                        mediaType: .video
                    )
                }

                if let deviceId: String = arguments["deviceId"] as? String,
                    !deviceId.isEmpty
                {
                    newCameraObject = capturedVideoDevices.first(where: {
                        $0.uniqueID == deviceId
                    })
                } else {
                    newCameraObject = capturedVideoDevices.first
                }

                self.isVideoMirrored =
                    arguments["isVideoMirrored"] as? Bool ?? false

                self.orientation = arguments["orientation"] as? Double ?? 0

                switch arguments["pformat"] as! String {
                case "jpg":
                    self.pictureFormat = NSBitmapImageRep.FileType.jpeg
                case "jepg":
                    self.pictureFormat = NSBitmapImageRep.FileType.jpeg2000
                case "bmp":
                    self.pictureFormat = NSBitmapImageRep.FileType.bmp
                case "png":
                    self.pictureFormat = NSBitmapImageRep.FileType.png
                case "raw":
                    self.pictureFormat = nil
                default:
                    self.pictureFormat = NSBitmapImageRep.FileType.tiff
                }
                switch arguments["vformat"] as! String {
                case "m4v":
                    self.videoFormat = AVFileType.m4v
                    self.vstring = "m4v"
                case "mov":
                    self.videoFormat = AVFileType.mov
                    self.vstring = "mov"
                default:
                    self.videoFormat = AVFileType.mp4
                    self.vstring = "mp4"
                }
                // If explicit format was requested, prefer that
                let requestedWidth = arguments["width"] as? Int
                let requestedHeight = arguments["height"] as? Int
                let requestedFps = arguments["fps"] as? Double
                let presetName = arguments["resolution"] as? String
                switch arguments["quality"] as! String {
                case "min":
                    self.audioQuality = AVAudioQuality.min
                case "low":
                    self.audioQuality = AVAudioQuality.low
                case "medium":
                    self.audioQuality = AVAudioQuality.medium
                case "high":
                    self.audioQuality = AVAudioQuality.high
                default:
                    self.audioQuality = AVAudioQuality.max
                }

                let afids: [AudioFormatID] = [
                    kAudioFormat60958AC3,
                    kAudioFormatAC3,
                    kAudioFormatAES3,
                    kAudioFormatALaw,
                    kAudioFormatAMR,
                    kAudioFormatAMR_WB,
                    kAudioFormatAppleIMA4,
                    kAudioFormatAppleLossless,
                    kAudioFormatAudible,
                    kAudioFormatDVIIntelIMA,
                    kAudioFormatEnhancedAC3,
                    kAudioFormatFLAC,
                    kAudioFormatLinearPCM,
                    kAudioFormatMACE3,
                    kAudioFormatMACE6,
                    kAudioFormatMIDIStream,
                    kAudioFormatMPEG4AAC,
                    kAudioFormatMPEG4AAC_ELD,
                    kAudioFormatMPEG4AAC_ELD_SBR,
                    kAudioFormatMPEG4AAC_ELD_V2,
                    kAudioFormatMPEG4AAC_HE,
                    kAudioFormatMPEG4AAC_HE_V2,
                    kAudioFormatMPEG4AAC_LD,
                    kAudioFormatMPEG4AAC_Spatial,
                    kAudioFormatMPEG4CELP,
                    kAudioFormatMPEG4HVXC,
                    kAudioFormatMPEG4TwinVQ,
                    kAudioFormatMPEGD_USAC,
                    kAudioFormatMPEGLayer1,
                    kAudioFormatMPEGLayer2,
                    kAudioFormatMPEGLayer3,
                    kAudioFormatMicrosoftGSM,
                    kAudioFormatOpus,
                    kAudioFormatParameterValueStream,
                    kAudioFormatQDesign,
                    kAudioFormatQDesign2,
                    kAudioFormatQUALCOMM,
                    kAudioFormatTimeCode,
                    kAudioFormatULaw,
                    kAudioFormatiLBC,
                ]

                self.audioFormat = afids[arguments["aformat"] as! Int]

                guard let newCameraObject: AVCaptureDevice = newCameraObject
                else {
                    result(
                        FlutterError(
                            code: "CAMERA_INITIALIZATION_ERROR",
                            message:
                                "Could not find a suitable camera on this device",
                            details: nil
                        ).toFlutterResult
                    )
                    return
                }
                self.videoDevice = newCameraObject
                do {
                    let focusPoint: CGPoint = .init(x: 0.5, y: 0.5)
                    let ti = arguments["torch"] as? Int
                    let torch: AVCaptureDevice.TorchMode =
                        (ti == nil || ti == 0) ? .off : (ti == 1 ? .on : .auto)
                    try newCameraObject.lockForConfiguration()
                    // Apply explicit format if requested or map preset to closest format
                    if let rw = requestedWidth, let rh = requestedHeight {
                        var best: AVCaptureDevice.Format? = nil
                        var bestDelta = Int.max
                        for f in newCameraObject.formats {
                            let desc = f.formatDescription
                            let dim = CMVideoFormatDescriptionGetDimensions(desc)
                            let delta = abs(Int(dim.width) - rw) + abs(Int(dim.height) - rh)
                            if delta < bestDelta { best = f; bestDelta = delta }
                        }
                        if let best = best {
                            newCameraObject.activeFormat = best
                            if let fps = requestedFps {
                                let ranges = best.videoSupportedFrameRateRanges
                                if let chosen = ranges.min(by: { (a, b) -> Bool in
                                    // Prefer a range that contains fps; otherwise choose closest by center distance
                                    let aContains = fps >= a.minFrameRate && fps <= a.maxFrameRate
                                    let bContains = fps >= b.minFrameRate && fps <= b.maxFrameRate
                                    if aContains != bContains { return aContains }
                                    let aCenter = (a.minFrameRate + a.maxFrameRate) / 2.0
                                    let bCenter = (b.minFrameRate + b.maxFrameRate) / 2.0
                                    return abs(aCenter - fps) < abs(bCenter - fps)
                                }) {
                                    // Pick the nearer end of the chosen range to avoid unsupported exact fractions
                                    let minDiff = abs(chosen.minFrameRate - fps)
                                    let maxDiff = abs(chosen.maxFrameRate - fps)
                                    let duration: CMTime = (minDiff <= maxDiff) ? chosen.minFrameDuration : chosen.maxFrameDuration
                                    newCameraObject.activeVideoMinFrameDuration = duration
                                    newCameraObject.activeVideoMaxFrameDuration = duration
                                }
                            }
                        }
                    } else if let presetName = presetName {
                        let target: (w:Int,h:Int) = {
                            switch presetName {
                            case "low": return (640,480)
                            case "medium": return (960,540)
                            case "high": return (1280,720)
                            case "veryHigh": return (1920,1080)
                            case "ultraHigh": return (3840,2160)
                            default: return (1280,720)
                            }
                        }()
                        var best: AVCaptureDevice.Format? = nil
                        var bestDelta = Int.max
                        for f in newCameraObject.formats {
                            let desc = f.formatDescription
                            let dim = CMVideoFormatDescriptionGetDimensions(desc)
                            let delta = abs(Int(dim.width) - target.w) + abs(Int(dim.height) - target.h)
                            if delta < bestDelta { best = f; bestDelta = delta }
                        }
                        if let best = best { newCameraObject.activeFormat = best }
                    }
                    if newCameraObject.isFocusModeSupported(.autoFocus) {
                        newCameraObject.focusMode = .autoFocus
                    }
                    if newCameraObject.isFocusPointOfInterestSupported {
                        newCameraObject.focusPointOfInterest = focusPoint
                    }
                    if newCameraObject.isExposureModeSupported(
                        .continuousAutoExposure
                    ) {
                        newCameraObject.exposureMode =
                            AVCaptureDevice.ExposureMode.continuousAutoExposure
                    }
                    if newCameraObject.isExposurePointOfInterestSupported {
                        newCameraObject.exposurePointOfInterest = focusPoint
                    }
                    if newCameraObject.isTorchModeSupported(torch) {
                        newCameraObject.torchMode = torch
                    }
                    newCameraObject.unlockForConfiguration()

                    let videoInput = try AVCaptureDeviceInput(
                        device: newCameraObject
                    )

                    if self.captureSession.canAddInput(videoInput) {
                        self.captureSession.addInput(videoInput)
                    }

                    let shouldRecordAudio =
                        arguments["enableAudio"] as? Bool ?? true
                    self.enableAudio = shouldRecordAudio

                    if shouldRecordAudio {
                        var capturedAudioDevices: [AVCaptureDevice] = []

                        if #available(macOS 10.15, *) {
                            capturedAudioDevices =
                                AVCaptureDevice.captureDevices(
                                    deviceTypes: [
                                        .builtInMicrophone, .externalUnknown,
                                    ],
                                    mediaType: .audio
                                )
                        } else {
                            capturedAudioDevices =
                                AVCaptureDevice.captureDevices(
                                    mediaType: .audio
                                )
                        }

                        var micObject: AVCaptureDevice!
                        if let audioDeviceId: String = arguments[
                            "audioDeviceId"
                        ] as? String, !audioDeviceId.isEmpty {
                            micObject = capturedAudioDevices.first(where: {
                                $0.uniqueID == audioDeviceId
                            })
                        } else {
                            micObject = AVCaptureDevice.default(for: .audio)
                        }
                        if let micObject = micObject {
                            let audioInput = try AVCaptureDeviceInput(
                                device: micObject
                            )
                            if self.captureSession.canAddInput(audioInput) {
                                self.captureSession.addInput(audioInput)
                                self.audioDevice = micObject
                            }
                        }
                    }

                    var outputInitialized = false

                    self.useMovieFileOutput =
                        arguments["useMovieFileOutput"] as? Bool ?? false

                    // Add video buffering output

                    if self.useMovieFileOutput {
                        let videoOutput = AVCaptureMovieFileOutput()
                        if self.captureSession.canAddOutput(videoOutput) {
                            self.captureSession.addOutput(videoOutput)
                            for connection in videoOutput.connections {
                                if connection.isVideoMirroringSupported {
                                    if connection.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                                        connection.automaticallyAdjustsVideoMirroring = false
                                    }
                                    connection.isVideoMirrored = self.isVideoMirrored
                                }
                                if #available(macOS 14.0, *),
                                    connection.isVideoRotationAngleSupported(
                                        self.orientation
                                    )
                                {
                                    connection.videoRotationAngle =
                                        self.orientation
                                }
                            }
                            outputInitialized = true
                        }
                    } else {
                        let videoOutput = AVCaptureVideoDataOutput()
                        if self.captureSession.canAddOutput(videoOutput) {
                            videoOutput.videoSettings = [
                                kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA
                            ]
                            videoOutput.alwaysDiscardsLateVideoFrames = true
                            videoOutput.setSampleBufferDelegate(
                                self,
                                queue: .main
                            )
                            self.captureSession.addOutput(videoOutput)
                            for connection in videoOutput.connections {
                                if connection.isVideoMirroringSupported {
                                    if connection.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                                        connection.automaticallyAdjustsVideoMirroring = false
                                    }
                                    connection.isVideoMirrored = self.isVideoMirrored
                                }
                                if #available(macOS 14.0, *),
                                    connection.isVideoRotationAngleSupported(
                                        self.orientation
                                    )
                                {
                                    connection.videoRotationAngle =
                                        self.orientation
                                }
                            }
                            outputInitialized = true
                        }

                        // Add audio buffering output
                        if shouldRecordAudio {
                            let audioOutput = AVCaptureAudioDataOutput()
                            if self.captureSession.canAddOutput(audioOutput) {
                                audioOutput.setSampleBufferDelegate(
                                    self,
                                    queue: .main
                                )
                                self.captureSession.addOutput(audioOutput)
                            }
                        }
                    }

                    guard outputInitialized else {
                        result(
                            FlutterError(
                                code: "CAMERA_INITIALIZATION_ERROR",
                                message:
                                    "Could not initialize output for camera",
                                details: nil
                            ).toFlutterResult
                        )
                        return
                    }

                    self.captureSession.commitConfiguration()
                    self.captureSession.startRunning()

                    let dimensions = CMVideoFormatDescriptionGetDimensions(
                        newCameraObject.activeFormat.formatDescription
                    )
                    self.videoOutputHeight = dimensions.height
                    self.videoOutputWidth = dimensions.width
                    let size = [
                        "width": Double(dimensions.width),
                        "height": Double(dimensions.height),
                    ]

                    if self.useMovieFileOutput {
                        if let previewLayer = self.previewLayer,
                            previewLayer.superlayer != nil
                        {
                            previewLayer.removeFromSuperlayer()
                        }
                        self.previewLayer = AVCaptureVideoPreviewLayer(
                            session: self.captureSession
                        )
                        self.previewLayer!.videoGravity = .resizeAspectFill
                        if let conn = self.previewLayer?.connection, conn.isVideoMirroringSupported {
                            if conn.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                                conn.automaticallyAdjustsVideoMirroring = false
                            }
                            conn.isVideoMirrored = self.isVideoMirrored
                        }
                        if let factory = self.factory {
                            factory.frame = CGRect(
                                x: 0,
                                y: 0,
                                width: Int(dimensions.width),
                                height: Int(dimensions.height)
                            )
                            factory.previewLayer = AVCaptureVideoPreviewLayer(
                                session: self.captureSession
                            )
                            if let conn = factory.previewLayer?.connection, conn.isVideoMirroringSupported {
                                if conn.responds(to: Selector(("setAutomaticallyAdjustsVideoMirroring:"))) {
                                    conn.automaticallyAdjustsVideoMirroring = false
                                }
                                conn.isVideoMirrored = self.isVideoMirrored
                            }
                        }
                    }

                    var devices: [[String: Any]] = []
                    if let videoDevice = self.videoDevice {
                        devices.append([
                            "deviceType": 0,
                            "localizedName": videoDevice.localizedName,
                            "manufacturer": videoDevice.manufacturer,
                            "deviceId": videoDevice.uniqueID,
                        ])
                    }

                    if let audioDevice = self.audioDevice {
                        devices.append([
                            "deviceType": 1,
                            "localizedName": audioDevice.localizedName,
                            "manufacturer": audioDevice.manufacturer,
                            "deviceId": audioDevice.uniqueID,
                        ])
                    }

                    let answer: [String: Any?] = [
                        "textureId": self.textureId,
                        "deviceId": self.videoDevice.uniqueID,
                        "size": size,
                    ]
                    result(answer)

                } catch {
                    result(
                        FlutterError(
                            code: "CAMERA_INITIALIZATION_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        ).toFlutterResult
                    )
                    return
                }
            } else {
                result(
                    FlutterError(
                        code: "CAMERA_INITIALIZATION_ERROR",
                        message: "Permission not granted",
                        details: nil
                    ).toFlutterResult
                )
            }
        }
    }

    func takePicture(_ result: @escaping FlutterResult) {
        if pictureFormat != nil {
            guard let imageBuffer = latestBuffer,
                let nsImage = imageFromSampleBuffer(imageBuffer: imageBuffer),
                let imageData = nsImage.representation(
                    using: pictureFormat!,
                    properties: [
                        NSBitmapImageRep.PropertyKey.currentFrame:
                            NSBitmapImageRep.PropertyKey.currentFrame.self
                    ]
                ), !imageData.isEmpty
            else {
                result([
                    "error": FlutterError(
                        code: "PHOTO_OUTPUT_ERROR",
                        message: "imageData is empty or invalid",
                        details: nil
                    ).toMap
                ])
                return
            }
            result(["imageData": imageData, "error": nil])
        } else {
            let nsImage = imageFromSampleBuffer(imageBuffer: latestBuffer)
            if nsImage != nil {
                let imageData = Data(
                    bytes: nsImage!.bitmapData!,
                    count: Int(nsImage!.bytesPerRow * Int(nsImage!.size.height))
                )
                result(["imageData": imageData, "error": nil])
            } else {
                result([
                    "error": FlutterError(
                        code: "PHOTO_OUTPUT_ERROR",
                        message: "imageData is empty or invalid",
                        details: nil
                    ).toMap
                ])
                return
            }
        }
    }

    func imageFromSampleBuffer(imageBuffer: CVPixelBuffer) -> NSBitmapImageRep?
    {
        CVPixelBufferLockBaseAddress(
            imageBuffer,
            CVPixelBufferLockFlags(rawValue: 0)
        )

        guard
            let baseAddress: UnsafeMutableRawPointer =
                CVPixelBufferGetBaseAddress(imageBuffer)
        else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Create a bitmap graphics context with the sample buffer data
        guard
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else {
            return nil
        }
    let quartzImage = context.makeImage()!

        CVPixelBufferUnlockBaseAddress(
            imageBuffer,
            CVPixelBufferLockFlags(rawValue: 0)
        )

        // Create an image object from the Quartz image
        // Apply digital zoom crop if zoomLevel > 1
        var cgImage = quartzImage
        if zoomLevel > 1.0 {
            zoomBaseSize = CGSize(width: width, height: height)
            cgImage = zoomCGImage(cgImage)
        }
        // Optionally downscale for preview to reduce UI load; recording remains full-res
        if let scale = previewDownscale, scale > 0.0, scale < 1.0 {
            let targetW = max(1, Int(Double(cgImage.width) * scale))
            let targetH = max(1, Int(Double(cgImage.height) * scale))
            if let scaled = downscaleCGImage(cgImage, width: targetW, height: targetH) {
                cgImage = scaled
            }
        }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    func zoomCGImage(_ image: CGImage) -> CGImage {
        let base = zoomBaseSize ?? CGSize(width: image.width, height: image.height)
        let x = (base.width - base.width / zoomLevel) / 2
        let y = (base.height - base.height / zoomLevel) / 2
        let toRect = CGRect(
            x: x,
            y: y,
            width: base.width / zoomLevel,
            height: base.height / zoomLevel
        )
        return image.cropping(to: toRect) ?? image
    }

    /// Simple Lanczos downscale using vImage for better quality than naive sampling.
    func downscaleCGImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let colorSpace = image.colorSpace else { return nil }
        var format = vImage_CGImageFormat(
            bitsPerComponent: UInt32(image.bitsPerComponent),
            bitsPerPixel: UInt32(image.bitsPerPixel),
            colorSpace: Unmanaged.passUnretained(colorSpace),
            bitmapInfo: image.bitmapInfo,
            version: 0,
            decode: nil,
            renderingIntent: image.renderingIntent
        )
        var srcBuffer = vImage_Buffer()
        defer { free(srcBuffer.data) }
        var error = vImageBuffer_InitWithCGImage(&srcBuffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        let destBytesPerRow = width * bytesPerPixel
        guard let destData = malloc(destBytesPerRow * height) else { return nil }
        var destBuffer = vImage_Buffer(data: destData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: destBytesPerRow)
        error = vImageScale_ARGB8888(&srcBuffer, &destBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        if error != kvImageNoError {
            free(destData); return nil
        }
        defer { free(destData) }
        return vImageCreateCGImageFromBuffer(&destBuffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }

    func toggleTorch(
        _ arguments: [String: Any],
        _ result: @escaping FlutterResult
    ) {
        let ti = arguments["torch"] as? Int
        let torch: AVCaptureDevice.TorchMode =
            (ti == nil || ti == 0) ? .off : (ti == 1 ? .on : .auto)

        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.isTorchModeSupported(torch) {
                videoDevice.torchMode = torch
                videoDevice.unlockForConfiguration()

                result(nil)
            } else {
                videoDevice.unlockForConfiguration()
                result([
                    "error": FlutterError(
                        code: "TOGGLE_TOURCH_ERROR",
                        message:
                            "This device does not have a light to turn on/off.",
                        details: nil
                    ).toMap
                ])
            }
        } catch {
            result([
                "error": FlutterError(
                    code: "TOGGLE_TOURCH_ERROR",
                    message:
                        "Could not lock device for configuration: \(error.localizedDescription)",
                    details: nil
                ).toMap
            ])
        }
    }

    func generateVideoFileURL(randomGUID: Bool = false) -> URL {
        let paths = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )
        var fileUrl = paths[0].appendingPathComponent("output." + vstring)
        if randomGUID {
            fileUrl = paths[0].appendingPathComponent(
                UUID().uuidString + "." + vstring
            )
        }
        return fileUrl
    }

    func startRecording(
        _ arguments: [String: Any],
        _ result: @escaping FlutterResult
    ) {
        // Set up the AVAssetWriter (to write to file)
        do {
            if !isRecording {
                let shouldRecordAudio =
                    arguments["enableAudio"] as? Bool ?? true

                enableAudio = shouldRecordAudio

                // Remove old file
                var fileUrl: URL!

                if let selectedURL = arguments["url"] as? String,
                    !selectedURL.isEmpty
                {
                    fileUrl = URL(fileURLWithPath: selectedURL)
                } else {
                    fileUrl = generateVideoFileURL(randomGUID: false)
                }

                try? FileManager.default.removeItem(at: fileUrl)

                let folderURL = fileUrl.deletingLastPathComponent()

                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(
                    atPath: folderURL.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue {
                    try? FileManager.default.createDirectory(
                        at: folderURL,
                        withIntermediateDirectories: true
                    )
                }

                videoOutputFileURL = fileUrl

                if useMovieFileOutput {
                    guard
                        let movieOutput: AVCaptureMovieFileOutput =
                            captureSession.outputs.first(where: {
                                $0 is AVCaptureMovieFileOutput
                            }) as? AVCaptureMovieFileOutput
                    else {
                        result(
                            FlutterError(
                                code: "START_RECORDING_ERROR",
                                message:
                                    "Could not start AVMovieFileOutput Recording",
                                details: nil
                            ).toFlutterResult
                        )
                        return
                    }
                    isRecording = true
                    savedResult = result
                    movieOutput.startRecording(
                        to: fileUrl,
                        recordingDelegate: self
                    )
                } else {
                    self.videoWriter = try AVAssetWriter(
                        outputURL: fileUrl,
                        fileType: videoFormat
                    )
                    print("Setting up AVAssetWriter")

                    guard let videoWriter = videoWriter else {
                        result(
                            FlutterError(
                                code: "CAMERA_INITIALIZATION_ERROR",
                                message: "Could not initialize Video Writer",
                                details: nil
                            ).toFlutterResult
                        )
                        return
                    }

                    videoWriter.shouldOptimizeForNetworkUse = true

                    videoOutputQueue = DispatchQueue(
                        label: "videoQueue",
                        qos: .utility,
                        attributes: .concurrent,
                        autoreleaseFrequency: DispatchQueue.AutoreleaseFrequency
                            .inherit,
                        target: DispatchQueue.global()
                    )
                    guard let videoOutputQueue = videoOutputQueue else {
                        result(
                            FlutterError(
                                code: "START_RECORDING_ERROR",
                                message: "videoOutputQueue not initialized",
                                details: nil
                            ).toFlutterResult
                        )
                        isRecording = false
                        return
                    }

                    videoOutputQueue.async {
                        // Add Video Writer Video Input
                        var videoWriterVideoInputSettings: [String: Any] = [
                            AVVideoWidthKey: self.videoOutputWidth!,
                            AVVideoHeightKey: self.videoOutputHeight!,
                        ]

                        if #available(macOS 10.13, *) {
                            videoWriterVideoInputSettings[AVVideoCodecKey] =
                                AVVideoCodecType.h264
                        } else {
                            videoWriterVideoInputSettings[AVVideoCodecKey] =
                                AVVideoCodecH264
                        }

                        // settingsAssistant removed: rely solely on explicit writer settings derived from hardware format

                        let videoWriterVideoInput = AVAssetWriterInput(
                            mediaType: .video,
                            outputSettings: videoWriterVideoInputSettings
                        )
                        videoWriterVideoInput.expectsMediaDataInRealTime = true
                        if videoWriter.canAdd(videoWriterVideoInput) {
                            videoWriter.add(videoWriterVideoInput)
                        }

                        // Add Video Writer Audio Input
                        if self.enableAudio {
                            let videoWriterAudioInputSettings: [String: Any] = [
                                AVFormatIDKey: self.audioFormat,
                                AVSampleRateKey: 44100,
                                AVEncoderBitRateKey: 64000,
                                AVNumberOfChannelsKey: 1,
                                AVEncoderAudioQualityKey: self.audioQuality,
                            ]

                            // settingsAssistant removed: keep default audio writer settings

                            let videoWriterAudioInput = AVAssetWriterInput(
                                mediaType: .audio,
                                outputSettings: videoWriterAudioInputSettings
                            )
                            videoWriterAudioInput.expectsMediaDataInRealTime =
                                true
                            if videoWriter.canAdd(videoWriterAudioInput) {
                                videoWriter.add(videoWriterAudioInput)
                            }
                        }

                        // video buffering output
                        if let videoOutput = self.captureSession.outputs.first(
                            where: { $0 is AVCaptureVideoDataOutput })
                            as? AVCaptureVideoDataOutput
                        {
                            videoOutput.setSampleBufferDelegate(
                                self,
                                queue: videoOutputQueue
                            )
                        }

                        // audio buffering output
                        if shouldRecordAudio {
                            if let audioOutput = self.captureSession.outputs
                                .first(where: { $0 is AVCaptureAudioDataOutput }
                                ) as? AVCaptureAudioDataOutput
                            {
                                audioOutput.setSampleBufferDelegate(
                                    self,
                                    queue: videoOutputQueue
                                )
                            }
                        }

                        print("Finished Setting up AVAssetWriter")

                        print("Starting AVAssetWriter Writing")
                        if videoWriter.startWriting() {
                            print("Started AVAssetWriter Writing")
                            videoWriter.startSession(
                                atSourceTime: CMTime(
                                    seconds: CACurrentMediaTime(),
                                    preferredTimescale: CMTimeScale(
                                        NSEC_PER_SEC
                                    )
                                ) /* CMTimeMakeWithSeconds(CACurrentMediaTime(), preferredTimescale: 240) */
                            )
                            self.isRecording = true
                            DispatchQueue.main.async {
                                if let maxVideoDuration = arguments[
                                    "maxVideoDuration"
                                ] as? Double, maxVideoDuration > 0 {
                                    if #available(macOS 10.12, *) {
                                        Timer.scheduledTimer(
                                            withTimeInterval: maxVideoDuration,
                                            repeats: false
                                        ) { timer in
                                            if self.isRecording
                                                && videoWriter.status
                                                    == .writing
                                            {
                                                self.stopRecording {
                                                    callbackResult in
                                                    DispatchQueue.main.async {
                                                        self.outputChannel
                                                            .invokeMethod(
                                                                "onVideoRecordingFinished",
                                                                arguments:
                                                                    callbackResult
                                                            )
                                                    }
                                                }
                                            }
                                            timer.invalidate()
                                        }
                                    } else {
                                        Timer.scheduledTimer(
                                            timeInterval: maxVideoDuration,
                                            target: self,
                                            selector: #selector(
                                                self.stopRecordingSelector
                                            ),
                                            userInfo: nil,
                                            repeats: false
                                        )
                                    }
                                }
                                result(["started": true, "error": nil])
                            }
                        } else {
                            result(
                                FlutterError(
                                    code: "START_RECORDING_ERROR",
                                    message:
                                        "Could not start AVAssetWriter session",
                                    details: nil
                                ).toFlutterResult
                            )
                        }
                    }
                }

            } else {
                result(
                    FlutterError(
                        code: "CONCURRENCY_ERROR",
                        message: "Already recording video",
                        details: nil
                    ).toFlutterResult
                )
            }
        } catch {
            result(
                FlutterError(
                    code: "START_RECORDING_ERROR",
                    message: error.localizedDescription,
                    details: nil
                ).toFlutterResult
            )
            return
        }
    }

    func stopRecording(_ result: @escaping FlutterResult) {
        guard let captureSession = captureSession, captureSession.isRunning
        else {
            result(
                FlutterError(
                    code: "CAMERA_INITIALIZATION_ERROR",
                    message: "CaptureSession not found or not running",
                    details: nil
                ).toFlutterResult
            )
            return
        }
        if !isRecording {
            result(
                FlutterError(
                    code: "CAMERA_NOT_RECORDING_ERROR",
                    message: "Camera not recording",
                    details: nil
                ).toFlutterResult
            )
            return
        }
        if useMovieFileOutput {
            guard
                let movieOutput: AVCaptureMovieFileOutput = self.captureSession
                    .outputs.first(where: { $0 is AVCaptureMovieFileOutput })
                    as? AVCaptureMovieFileOutput
            else {
                result(
                    FlutterError(
                        code: "STOP_RECORDING_ERROR",
                        message:
                            "Could not stop AVMovieFileOutput Recording - Output not found",
                        details: nil
                    ).toFlutterResult
                )
                return
            }
            isRecording = false
            savedResult = result
            movieOutput.stopRecording()
        } else {
            guard let videoWriter = videoWriter,
                let videoOutputFileURL = videoOutputFileURL,
                let videoWriterVideoInput = videoWriter.inputs.first(where: {
                    $0.mediaType == .video
                }), let videoOutputQueue: DispatchQueue = videoOutputQueue
            else {
                result(
                    FlutterError(
                        code: "CAMERA_INITIALIZATION_ERROR",
                        message: "AVAssetWriter not found",
                        details: nil
                    ).toFlutterResult
                )
                return
            }
            isRecording = false
            videoOutputQueue.async {
                if videoWriter.status == .writing {
                    videoWriterVideoInput.markAsFinished()
                    if self.enableAudio,
                        let videoWriterAudioInput = videoWriter.inputs.first(
                            where: { $0.mediaType == .audio })
                    {
                        videoWriterAudioInput.markAsFinished()
                    }
                }
                if let latestFrameWrittenTimeStamp = self
                    .latestVideoFrameWrittenTimeStamp
                {
                    videoWriter.endSession(
                        atSourceTime: latestFrameWrittenTimeStamp
                    )
                }
                videoWriter.finishWriting {
                    let videoWriterStatus: AVAssetWriter.Status = videoWriter
                        .status
                    print(
                        "Finished AVAssetWriter Writing with status: \(videoWriterStatus)"
                    )
                    DispatchQueue.main.async {
                        switch videoWriterStatus {
                        case .completed:
                            guard
                                let videoData = try? Data(
                                    contentsOf: videoOutputFileURL
                                ), !videoData.isEmpty
                            else {
                                result([
                                    "error": FlutterError(
                                        code: "ASSET_WRITER_FAIL",
                                        message:
                                            "File is empty at url: \(videoOutputFileURL.absoluteURL)",
                                        details: nil
                                    ).toFlutterResult
                                ])
                                return
                            }
                            print(
                                "Video Recorded And Saved At: \(videoOutputFileURL.absoluteURL)"
                            )
                            result(
                                [
                                    "deviceId": self.videoDevice.uniqueID,
                                    "videoData": videoData,
                                    "url": videoOutputFileURL.absoluteURL.path,
                                    "error": nil,
                                ] as [String: Any?]
                            )
                        default:
                            result(
                                FlutterError(
                                    code: "ASSET_WRITER_FAIL",
                                    message:
                                        "File not saved at \(videoOutputFileURL.absoluteURL.path) - \(videoWriter.error?.localizedDescription ?? "")",
                                    details: nil
                                ).toFlutterResult
                            )
                        }
                        self.videoWriter = nil
                    }
                }
            }
        }
    }

    @objc
    func stopRecordingSelector() {
        if isRecording {
            stopRecording { callbackResult in
                DispatchQueue.main.async {
                    self.outputChannel.invokeMethod(
                        "onVideoRecordingFinished",
                        arguments: callbackResult
                    )
                }
            }
        }
    }

    func destroy(_ completion: @escaping () -> Void) {
        if videoDevice == nil {
            completion()
            return
        }

        isDestroyed = true

        if isRecording, let videoWriter = videoWriter,
            videoWriter.status == .writing
        {
            videoWriter.cancelWriting()
            isRecording = false
            self.videoWriter = nil
        }

        captureSession.stopRunning()
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }
        for output in captureSession.outputs {
            captureSession.removeOutput(output)
        }

        if let textureId = textureId {
            registry.unregisterTexture(textureId)
        }

        latestBuffer = nil
        captureSession = nil
        videoDevice = nil
        textureId = nil

        completion()
    }

    private var latestVideoFrameWrittenTimeStamp: CMTime!
    private var latestAudioFrameWrittenTimeStamp: CMTime!

    var canWrite: Bool {
        videoWriter != nil && videoWriter!.status == .writing
    }

    func setFocusPoint(
        _ arguments: [String: Any],
        _ result: @escaping FlutterResult
    ) {
        let x = arguments["x"] as! Double
        let y = arguments["y"] as! Double

        let focusPoint = CGPoint(x: x, y: y)

        do {
            try videoDevice.lockForConfiguration()
            if videoDevice.isFocusPointOfInterestSupported {
                videoDevice.focusPointOfInterest = focusPoint
                videoDevice.unlockForConfiguration()
                result(nil)
            } else {
                videoDevice.unlockForConfiguration()
                result([
                    "error": FlutterError(
                        code: "SET_FOCUSPOINT_ERROR",
                        message:
                            "This device does not have focuspoint support.",
                        details: nil
                    ).toMap
                ])
            }
        } catch {
            result([
                "error": FlutterError(
                    code: "SET_FOCUSPOINT_ERROR",
                    message:
                        "Could not lock device for configuration: \(error.localizedDescription)",
                    details: nil
                ).toMap
            ])
        }
    }

    func requestPermission(completionHandler: @escaping (Bool) -> Void) {
        if #available(macOS 10.14, *) {
            AVCaptureDevice.requestAccess(
                for: .video,
                completionHandler: completionHandler
            )
        } else {
            completionHandler(false)
        }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isDestroyed, textureId != nil else {
            return
        }

        let isBufferAudio: Bool = output is AVCaptureAudioDataOutput

        i += 1

        if !isBufferAudio {
            // Apply preview FPS throttling
            let now = CACurrentMediaTime()
            if let maxFps = previewMaxFPS, maxFps > 0 {
                let minDelta = 1.0 / maxFps
                if now - lastPreviewFrameTime < minDelta {
                    // Skip this frame for preview; still feed recorder below
                } else {
                    lastPreviewFrameTime = now
                    latestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                    registry.textureFrameAvailable(textureId)
                }
            } else {
                latestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                registry.textureFrameAvailable(textureId)
            }
        }

        if !useMovieFileOutput, isRecording,
            let captureSession = captureSession, captureSession.isRunning,
            let videoWriter = videoWriter,
            let videoOutputQueue = videoOutputQueue,
            CMSampleBufferDataIsReady(sampleBuffer)
        {
            videoOutputQueue.async {
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                if self.enableAudio, isBufferAudio,
                    let audio = videoWriter.inputs.first(where: {
                        $0.mediaType == .audio
                    }), !connection.audioChannels.isEmpty,
                    let connectionOutput = connection.output,
                    connectionOutput.connection(with: .audio) != nil,
                    audio.isReadyForMoreMediaData
                {
                    if let latestAudioFrameWrittenTimeStamp = self
                        .latestAudioFrameWrittenTimeStamp,
                        latestAudioFrameWrittenTimeStamp > time
                    {
                        print(
                            "Wrong frame order: Previous: \(latestAudioFrameWrittenTimeStamp) - Current: \(time)"
                        )
                        return
                    }
                    if self.canWrite {
                        let result: Bool = audio.append(sampleBuffer)
                        if !result && videoWriter.status == .failed {
                            print(
                                "Failed to write audio input: AVAssetWriter Error - "
                                    + videoWriter.error.debugDescription
                                    + " - Frame Order: "
                                    + "Previous: \(String(describing: self.latestAudioFrameWrittenTimeStamp)) - Current: \(time)"
                            )
                        } else if result {
                            self.latestAudioFrameWrittenTimeStamp = time
                        }
                    }
                }
                if !isBufferAudio,
                    let camera = videoWriter.inputs.first(where: {
                        $0.mediaType == .video
                    }), let connectionOutput = connection.output,
                    connectionOutput.connection(with: .video) != nil,
                    camera.isReadyForMoreMediaData
                {
                    if let latestVideoFrameWrittenTimeStamp = self
                        .latestVideoFrameWrittenTimeStamp,
                        latestVideoFrameWrittenTimeStamp > time
                    {
                        print(
                            "Wrong frame order: Previous: \(latestVideoFrameWrittenTimeStamp) - Current: \(time)"
                        )
                        return
                    }
                    if self.canWrite {
                        let result: Bool = camera.append(sampleBuffer)
                        if !result && videoWriter.status == .failed {
                            print(
                                "Failed to write video input: AVAssetWriter Error - "
                                    + videoWriter.error.debugDescription
                                    + " - Frame Order: "
                                    + "Previous: \(String(describing: self.latestVideoFrameWrittenTimeStamp)) - Current: \(time)"
                            )
                        } else if result {
                            self.latestVideoFrameWrittenTimeStamp = time
                        }
                    }
                }
            }
        }

    // Remove old analyzer throttle that interfered with frame delivery.
    }

    // MOVIE FILE OUTPUT MODE
    func fileOutput(
        _: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from _: [AVCaptureConnection],
        error: Error?
    ) {
        guard let savedResult = savedResult else {
            print("FlutterResult callback not registered")
            return
        }
        if let error = error {
            savedResult(
                FlutterError(
                    code: "MOVIE_FILE_OUTPUT_FAIL",
                    message:
                        "File not saved at \(videoOutputFileURL.absoluteURL.path) - \(error.localizedDescription)",
                    details: nil
                ).toFlutterResult
            )
            return
        }
        guard let videoData = try? Data(contentsOf: outputFileURL),
            !videoData.isEmpty
        else {
            savedResult([
                "error": FlutterError(
                    code: "MOVIE_FILE_OUTPUT_FAIL",
                    message:
                        "File is empty at url: \(outputFileURL.absoluteURL)",
                    details: nil
                ).toFlutterResult
            ])
            return
        }
        print("Video Recorded And Saved At: \(outputFileURL.absoluteURL)")
        savedResult(
            [
                "videoData": videoData, "url": outputFileURL.absoluteURL.path,
                "error": nil,
            ] as [String: Any?]
        )
    }
}

// Extension for UnsafeMutableRawPointer remains unchanged
extension UnsafeMutableRawPointer {
    // Converts the vImage buffer to CVPixelBuffer
    func toCVPixelBuffer(
        pixelBuffer: CVPixelBuffer,
        targetWith: Int,
        targetHeight: Int,
        targetImageRowBytes: Int
    ) -> CVPixelBuffer? {
        let pixelBufferType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let releaseCallBack: CVPixelBufferReleaseBytesCallback = { _, pointer in
            if let pointer = pointer {
                free(UnsafeMutableRawPointer(mutating: pointer))
            }
        }

        var targetPixelBuffer: CVPixelBuffer?
        let conversionStatus = CVPixelBufferCreateWithBytes(
            nil,
            targetWith,
            targetHeight,
            pixelBufferType,
            self,
            targetImageRowBytes,
            releaseCallBack,
            nil,
            nil,
            &targetPixelBuffer
        )

        guard conversionStatus == kCVReturnSuccess else {
            free(self)
            return nil
        }

        return targetPixelBuffer
    }
}
