//
//  AVCaptureDevice+Extension.swift
//  camera_macos
//
//  Created by riccardo on 04/11/22.
//

import Foundation
import AVFoundation

extension AVCaptureDevice {
    
    @available(macOS 10.15, *)
    public class func captureDevice(deviceTypes: [AVCaptureDevice.DeviceType], mediaType: AVMediaType) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: mediaType, position: .unspecified).devices
        return devices.first
    }
    
    @available(macOS 10.15, *)
    public class func captureDevices(deviceTypes: [AVCaptureDevice.DeviceType], mediaType: AVMediaType? = nil) -> [AVCaptureDevice] {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: mediaType, position: .unspecified).devices
        return devices
    }
    
    public class func captureDevice(mediaType: AVMediaType) -> AVCaptureDevice? {
        if #available(macOS 10.15, *) {
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: mediaType, position: .unspecified).devices
            return devices.first
        } else {
            // Fallback (deprecated APIs avoided by returning nil)
            return nil
        }
    }

    public class func captureDevices(mediaType: AVMediaType? = nil) -> [AVCaptureDevice] {
        if let mediaType = mediaType {
            if #available(macOS 10.15, *) {
                return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: mediaType, position: .unspecified).devices
            } else {
                return []
            }
        } else {
            if #available(macOS 10.15, *) {
                let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .externalUnknown], mediaType: .video, position: .unspecified).devices
                let audio = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
                return video + audio
            } else {
                return []
            }
        }
    }
    
}
