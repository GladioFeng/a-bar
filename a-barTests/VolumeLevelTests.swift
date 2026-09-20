import XCTest

/// CoreAudio reports and accepts volume on one scale, 0 to 1. The widget used to re-derive that
/// at four places and disagreed with itself at one of them.
final class VolumeLevelTests: XCTestCase {

  // MARK: - There is one scale

  func testAReadingIsTakenAsItComes() {
    XCTAssertEqual(VolumeLevel.normalize(0), 0, accuracy: 0.001)
    XCTAssertEqual(VolumeLevel.normalize(0.5), 0.5, accuracy: 0.001)
    XCTAssertEqual(VolumeLevel.normalize(1), 1, accuracy: 0.001)
  }

  func testAReadingOutsideTheDocumentedRangeIsClamped() {
    // regression: one of the four copies of this had no clamp at all, so an out-of-range reading
    // drove the popover slider past its own track.
    XCTAssertEqual(VolumeLevel.normalize(-0.5), 0, accuracy: 0.001)
    XCTAssertEqual(VolumeLevel.normalize(1.5), 1, accuracy: 0.001)
  }

  func testWritingBackUsesTheSameScaleAsReading() {
    // regression: the commit path asked whether the *current* reading looked like a 0-100 value
    // and, if so, multiplied the slider position by 100 on the way out. No CoreAudio device
    // reports on that scale - `kAudioDevicePropertyVolumeScalar` is 0...1 and `setSystemVolume`
    // clamps to it - so the branch was unreachable. Had it ever been taken, 0.5 would have gone
    // out as 50, clamped straight to 1.0, and set the volume to maximum.
    XCTAssertEqual(VolumeLevel.denormalize(0.5), 0.5, accuracy: 0.001)
    XCTAssertEqual(VolumeLevel.denormalize(0), 0, accuracy: 0.001)
    XCTAssertEqual(VolumeLevel.denormalize(1), 1, accuracy: 0.001)
  }

  func testAValueRoundTripsThroughBothDirections() {
    for step in 0...20 {
      let value = Double(step) / 20

      XCTAssertEqual(
        VolumeLevel.normalize(VolumeLevel.denormalize(value)), value, accuracy: 0.001,
        "round trip at \(value)")
    }
  }

  // MARK: - The speaker icon

  func testSilenceAndMuteLookDifferent() {
    // Volume zero and muted are different states, and turning the volume up from zero works
    // where unmuting is needed for the other.
    XCTAssertEqual(VolumeLevel.speakerIcon(0, isMuted: false), "speaker.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(0, isMuted: true), "speaker.slash.fill")
  }

  func testMuteOutranksTheLevel() {
    XCTAssertEqual(VolumeLevel.speakerIcon(1, isMuted: true), "speaker.slash.fill")
  }

  func testTheWaveCountFollowsTheLevel() {
    XCTAssertEqual(VolumeLevel.speakerIcon(0.1, isMuted: false), "speaker.wave.1.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(0.32, isMuted: false), "speaker.wave.1.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(0.33, isMuted: false), "speaker.wave.2.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(0.65, isMuted: false), "speaker.wave.2.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(0.66, isMuted: false), "speaker.wave.3.fill")
    XCTAssertEqual(VolumeLevel.speakerIcon(1, isMuted: false), "speaker.wave.3.fill")
  }

  // MARK: - The microphone icon

  func testAMutedOrSilentMicrophoneIsStruckThrough() {
    XCTAssertEqual(VolumeLevel.microphoneIcon(0, isMuted: false), "mic.slash.fill")
    XCTAssertEqual(VolumeLevel.microphoneIcon(0.5, isMuted: true), "mic.slash.fill")
    XCTAssertEqual(VolumeLevel.microphoneIcon(0.5, isMuted: false), "mic.fill")
  }

  // MARK: - The percentage

  func testTheLevelReadsAsAWholePercentage() {
    XCTAssertEqual(VolumeLevel.percentText(0, isMuted: false), "0%")
    XCTAssertEqual(VolumeLevel.percentText(0.5, isMuted: false), "50%")
    XCTAssertEqual(VolumeLevel.percentText(1, isMuted: false), "100%")
  }

  func testAMutedDeviceShowsADashRatherThanZero() {
    XCTAssertEqual(
      VolumeLevel.percentText(0.5, isMuted: true), "-%",
      "otherwise muting at half volume still reads 50%")
  }
}
