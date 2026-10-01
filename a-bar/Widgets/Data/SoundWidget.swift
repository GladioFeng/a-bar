import AppKit
import SwiftUI

/// Sound/Volume widget
struct SoundWidget: View {
  let position: BarPosition
  
  @EnvironmentObject var settings: SettingsManager
  @EnvironmentObject var systemInfo: SystemInfoService

  @StateObject private var popoverManager = WidgetPopoverManager()

  private var globalSettings: GlobalSettings {
    settings.settings.global
  }

  private var soundSettings: SoundWidgetSettings {
    settings.settings.widgets.sound
  }

  private var theme: ABarTheme {
    ThemeManager.currentTheme(for: settings.settings.theme)
  }

  var body: some View {
    let bgColor = soundSettings.backgroundColor.color(from: theme)
    let fgColor =
      globalSettings.noColorInDataWidgets ? 
        theme.foreground : 
        bgColor.contrastingForeground(from: theme, opacity: globalSettings.barElementsBackgroundOpacity, barBackground: theme.background)

    BaseWidgetView(
      backgroundColor: globalSettings.noColorInDataWidgets ? theme.minor : bgColor,
      onClick: {
        if !popoverManager.isOpen {
          NSApp.activate(ignoringOtherApps: true)
        }
        popoverManager.toggle()
      },
      onRightClick: openSoundPreferences
    ) {
      HStack(spacing: 4) {
        if soundSettings.showIcon {
          Image(systemName: volumeIcon)
            .font(.system(size: 11))
            .foregroundColor(fgColor)
        }

        Text(volumeText)
          .foregroundColor(fgColor)
      }
    }
    .background(
      WidgetPopoverAnchor(
        onMake: { view in
          popoverManager.attach(anchorView: view, position: position)

          // Set popover content using a dedicated SwiftUI view so it keeps its own state
          let commit: (Double) -> Void = { v in
            systemInfo.setSystemVolume(VolumeLevel.denormalize(v))
          }

          let toggle: () -> Void = {
            systemInfo.setSystemMuted(!systemInfo.isMuted)
          }

          let openPrefs: () -> Void = {
            openSoundPreferences()
          }

          popoverManager.setContent {
            PopoverContent(
              sliderValue: normalizedVolume,
              onCommit: commit, onToggleMute: toggle, onOpenPrefs: openPrefs
            )
            .environmentObject(settings)
            .environmentObject(systemInfo)
          }
        }
      ))
  }

  private var normalizedVolume: Double {
    VolumeLevel.normalize(systemInfo.volumeLevel)
  }

  private var volumeIcon: String {
    VolumeLevel.speakerIcon(normalizedVolume, isMuted: systemInfo.isMuted)
  }

  private var volumeText: String {
    VolumeLevel.percentText(normalizedVolume, isMuted: systemInfo.isMuted)
  }

  struct PopoverContent: View {
    @EnvironmentObject var systemInfo: SystemInfoService
    @State var sliderValue: Double
    @EnvironmentObject var settings: SettingsManager
    private var theme: ABarTheme { ThemeManager.currentTheme(for: settings.settings.theme) }
    private var globalSettings: GlobalSettings { settings.settings.global }
    let onCommit: (Double) -> Void
    let onToggleMute: () -> Void
    let onOpenPrefs: () -> Void

    private var normalizedVolume: Double {
      VolumeLevel.normalize(systemInfo.volumeLevel)
    }

    var body: some View {
      VStack(spacing: 6) {
        // Audio device name
        if !systemInfo.audioOutputDeviceName.isEmpty {
          Text(systemInfo.audioOutputDeviceName)
            .font(
                globalSettings.fontName.isEmpty
                    ? .system(size: CGFloat(globalSettings.fontSize))
                    : .custom(globalSettings.fontName, size: CGFloat(globalSettings.fontSize))
            )
            .foregroundColor(theme.foreground.opacity(0.8))
            .padding(.top, 4)
        }
        
        HStack(spacing: 8) {
          Button(action: onToggleMute) {
            Image(systemName: systemInfo.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .font(.system(size: 12, weight: .regular))
              .foregroundColor(theme.foreground)
          }

          Slider(
            value: $sliderValue, in: 0...1,
            onEditingChanged: { editing in
              if !editing {
                onCommit(sliderValue)
              }
            }
          )
          .frame(minWidth: 120, maxWidth: 200)

          Button(action: onOpenPrefs) {
            Image(systemName: "gearshape")
              .font(.system(size: 12, weight: .regular))
              .foregroundColor(theme.foreground)
          }
        }
        .padding(8)
        .padding(.top, 2)
      }
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(globalSettings.noColorInDataWidgets ? theme.minor : theme.background)
          .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
      )
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 6)
      .onAppear {
        sliderValue = normalizedVolume
      }
      .onReceive(systemInfo.$volumeLevel) { newLevel in
        // update slider while open when system volume changes externally
        sliderValue = VolumeLevel.normalize(newLevel)
      }
    }
  }

  private func openSoundPreferences() {
    Task {
      _ = try? await ShellExecutor.run("open /System/Library/PreferencePanes/Sound.prefPane/")
    }
  }
}
