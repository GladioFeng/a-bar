import Foundation

/// Output and input volume as the bar shows it.
///
/// CoreAudio reports and accepts `kAudioDevicePropertyVolumeScalar`, which is 0...1 by
/// definition, and `SystemInfoService.setSystemVolume` clamps to that range before writing. The
/// widget used to re-check at four places whether the reading might be on a 0-100 scale instead,
/// and one of those branches multiplied the slider value by 100 on the way back out. That branch
/// could never be taken - and had it been, the value would have been clamped straight to 1.0,
/// setting the volume to maximum. There is one scale, and this is it.
enum VolumeLevel {

  /// A reading from the system, clamped to the range it is documented to be in.
  static func normalize(_ raw: Float) -> Double {
    Double(min(max(raw, 0), 1))
  }

  /// The value to write back, in the same scale it was read in.
  static func denormalize(_ normalized: Double) -> Float {
    Float(min(max(normalized, 0), 1))
  }

  static func speakerIcon(_ normalized: Double, isMuted: Bool) -> String {
    if isMuted { return "speaker.slash.fill" }
    if normalized == 0 { return "speaker.fill" }
    if normalized < 0.33 { return "speaker.wave.1.fill" }
    if normalized < 0.66 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
  }

  static func microphoneIcon(_ normalized: Double, isMuted: Bool) -> String {
    isMuted || normalized == 0 ? "mic.slash.fill" : "mic.fill"
  }

  /// A muted device shows a dash rather than a number, because zero and muted are different
  /// states and the user needs to tell them apart.
  static func percentText(_ normalized: Double, isMuted: Bool) -> String {
    isMuted ? "-%" : "\(Int(normalized * 100))%"
  }
}
