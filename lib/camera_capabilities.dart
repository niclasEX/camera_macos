class CameraCapabilities {
  final bool supportsFocusPoint;
  final List<FocusMode> focusModes;
  final bool supportsExposurePoint;
  final List<ExposureMode> exposureModes;
  final List<WhiteBalanceMode> whiteBalanceModes;
  final bool supportsManualWhiteBalanceGains;
  final bool supportsManualExposure;
  final bool supportsHardwareZoom;
  final bool supportsTorch;
  final bool supportsMirroring;
  final bool supportsRotation;
  final List<Resolution> supportedResolutions;

  const CameraCapabilities({
    required this.supportsFocusPoint,
    required this.focusModes,
    required this.supportsExposurePoint,
    required this.exposureModes,
    required this.whiteBalanceModes,
    required this.supportsManualWhiteBalanceGains,
    required this.supportsManualExposure,
    required this.supportsHardwareZoom,
    required this.supportsTorch,
    required this.supportsMirroring,
    required this.supportsRotation,
    required this.supportedResolutions,
  });

  factory CameraCapabilities.fromMap(Map<String, dynamic> map) {
    List<String> _strings(dynamic v) =>
        (v as List?)?.cast<String>() ?? const [];
    List<Map<String, dynamic>> _mapList(dynamic v) =>
        (v as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .cast<Map<String, dynamic>>()
            .toList() ??
        const [];

    return CameraCapabilities(
      supportsFocusPoint: map['supportsFocusPoint'] == true,
      focusModes: _strings(map['focusModes'])
          .map(FocusModeX.fromString)
          .whereType<FocusMode>()
          .toList(),
      supportsExposurePoint: map['supportsExposurePoint'] == true,
      exposureModes: _strings(map['exposureModes'])
          .map(ExposureModeX.fromString)
          .whereType<ExposureMode>()
          .toList(),
      whiteBalanceModes: _strings(map['whiteBalanceModes'])
          .map(WhiteBalanceModeX.fromString)
          .whereType<WhiteBalanceMode>()
          .toList(),
      supportsManualWhiteBalanceGains:
          map['supportsManualWhiteBalanceGains'] == true,
      supportsManualExposure: map['supportsManualExposure'] == true,
      supportsHardwareZoom: map['supportsHardwareZoom'] == true,
      supportsTorch: map['supportsTorch'] == true,
      supportsMirroring: map['supportsMirroring'] == true,
      supportsRotation: map['supportsRotation'] == true,
      supportedResolutions: _mapList(map['supportedResolutions'])
          .map((e) => Resolution(
                width: (e['width'] as num?)?.toInt() ?? 0,
                height: (e['height'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
    );
  }
}

class Resolution {
  final int width;
  final int height;
  const Resolution({required this.width, required this.height});
  @override
  String toString() => '${width}x$height';
}

enum FocusMode { auto, continuous, locked }

class FocusModeX {
  static String name(FocusMode m) {
    switch (m) {
      case FocusMode.auto:
        return 'auto';
      case FocusMode.continuous:
        return 'continuous';
      case FocusMode.locked:
        return 'locked';
    }
  }

  static FocusMode? fromString(String s) {
    switch (s) {
      case 'auto':
        return FocusMode.auto;
      case 'continuous':
        return FocusMode.continuous;
      case 'locked':
        return FocusMode.locked;
    }
    return null;
  }
}

enum ExposureMode { auto, continuous, locked }

class ExposureModeX {
  static String name(ExposureMode m) {
    switch (m) {
      case ExposureMode.auto:
        return 'auto';
      case ExposureMode.continuous:
        return 'continuous';
      case ExposureMode.locked:
        return 'locked';
    }
  }

  static ExposureMode? fromString(String s) {
    switch (s) {
      case 'auto':
        return ExposureMode.auto;
      case 'continuous':
        return ExposureMode.continuous;
      case 'locked':
        return ExposureMode.locked;
    }
    return null;
  }
}

enum WhiteBalanceMode { auto, continuous, locked }

class WhiteBalanceModeX {
  static String name(WhiteBalanceMode m) {
    switch (m) {
      case WhiteBalanceMode.auto:
        return 'auto';
      case WhiteBalanceMode.continuous:
        return 'continuous';
      case WhiteBalanceMode.locked:
        return 'locked';
    }
  }

  static WhiteBalanceMode? fromString(String s) {
    switch (s) {
      case 'auto':
        return WhiteBalanceMode.auto;
      case 'continuous':
        return WhiteBalanceMode.continuous;
      case 'locked':
        return WhiteBalanceMode.locked;
    }
    return null;
  }
}
