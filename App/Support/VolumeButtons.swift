import AVFoundation
import ClementineKit
import MediaPlayer
import SwiftUI

/// Makes the phone's volume buttons change Clementine's volume, while the app is in front. While
/// Clementine plays on the phone itself, they change the phone's volume as usual.
///
/// iOS has no API for the buttons, so the app keeps an ambient audio session active (it plays
/// nothing and interrupts nothing), watches the session's output volume, and after each press puts
/// the phone's volume back through a hidden MPVolumeView. With an MPVolumeView on screen iOS
/// doesn't show its volume HUD.
@MainActor
final class VolumeButtonController {
    private let model: AppModel
    private weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    /// The phone volume the app keeps putting back.
    private var reference: Float = 0.5
    /// Set while the app itself is changing the phone's volume.
    private var restoring: Float?

    init(model: AppModel) {
        self.model = model
    }

    func attach(_ volumeView: MPVolumeView) {
        self.volumeView = volumeView
    }

    /// Listens to the buttons when [enabled], and stops otherwise.
    func update(enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard observation == nil else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.ambient, options: [.mixWithOthers])
            try audio.setActive(true)
        } catch {
            return
        }
        reference = audio.outputVolume
        // At either end, a press one way wouldn't register.
        if reference <= 0.05 || reference >= 0.95 {
            setPhoneVolume(0.5)
        }
        observation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.changed(to: volume) }
        }
    }

    private func stop() {
        guard observation != nil else { return }
        observation?.invalidate()
        observation = nil
        // While Clementine plays here, the session is the renderer's, playing.
        if model.renderer.item == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func changed(to volume: Float) {
        if let restoring, abs(volume - restoring) < 0.001 {
            self.restoring = nil
            return
        }
        guard abs(volume - reference) > 0.001 else { return }
        let step = model.settings.volumeStep
        let clementine = model.session.changeVolume(by: volume > reference ? step : -step)
        model.toasts.show("Volume \(clementine)%")
        setPhoneVolume(reference)
    }

    private func setPhoneVolume(_ volume: Float) {
        reference = volume
        restoring = volume
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // The slider ignores changes made straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            slider.value = volume
        }
    }
}

/// A nearly invisible MPVolumeView, which the controller uses and which hides iOS's volume HUD.
struct VolumeButtonsView: UIViewRepresentable {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingKey.volumeButtons) private var enabled = true

    func makeCoordinator() -> VolumeButtonController {
        VolumeButtonController(model: model)
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 10, height: 10))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        context.coordinator.update(
            enabled: enabled && scenePhase == .active && model.session.status.isActive && !model.session.isPlayingHere)
    }

    static func dismantleUIView(_ view: MPVolumeView, coordinator: VolumeButtonController) {
        coordinator.update(enabled: false)
    }
}
