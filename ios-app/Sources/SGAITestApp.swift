//  PoC SGAI — probador con el reproductor NATIVO de iOS.
//
//  Proyecto de Xcode generado con XcodeGen (ios-app/project.yml). La compilación
//  se verifica en CI sobre un runner macOS, así que el código no es una promesa
//  sin comprobar.
//
//  Por qué hace falta: Safari no ejecuta HLS Interstitials — comprobado contra
//  el stream de referencia de Apple, que en el dispositivo reproduce sólo el
//  contenido primario. Son una funcionalidad de AVFoundation.
//
//  AVPlayerInterstitialEventMonitor expone la agenda de interstitials que el
//  player ha extraído del manifiesto y avisa al entrar y salir de cada uno. Ésa
//  es la traza que no se ve desde fuera: distingue "el player no reconoce el
//  DATERANGE" de "lo reconoce pero no lo ejecuta".
//
//  HTTP en claro vale: el Info.plist del proyecto lleva NSAllowsArbitraryLoads,
//  así que ATS no bloquea la conexión al servidor del PoC. No hace falta HTTPS.

import SwiftUI
import AVKit
import AVFoundation

@main
struct SGAITestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var urlText = "http://CAMBIA-ESTO:8081/master.m3u8?profile=replace"
    @StateObject private var model = PlayerModel()

    var body: some View {
        VStack(spacing: 10) {
            TextField("URL del master.m3u8", text: $urlText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.caption)

            Button("Cargar") { model.load(urlText) }
                .buttonStyle(.borderedProminent)

            VideoPlayer(player: model.player)
                .frame(height: 200)
                .background(Color.black)

            HStack {
                Text("agenda: \(model.scheduledCount)")
                Spacer()
                Text(model.inInterstitial ? "EN ANUNCIO" : "contenido")
                    .foregroundStyle(model.inInterstitial ? .green : .secondary)
                    .bold()
            }
            .font(.footnote)

            List(model.log) { e in
                HStack(alignment: .top, spacing: 6) {
                    Text(e.time).foregroundStyle(.secondary)
                    Text(e.message)
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .listStyle(.plain)
        }
        .padding()
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let message: String
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var log: [LogEntry] = []
    @Published var scheduledCount = 0
    @Published var inInterstitial = false

    private var monitor: AVPlayerInterstitialEventMonitor?
    private var observers: [NSObjectProtocol] = []

    func load(_ urlString: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            add("URL inválida"); return
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        player.replaceCurrentItem(with: AVPlayerItem(url: url))

        let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: player)
        self.monitor = monitor
        let nc = NotificationCenter.default

        // La agenda se puebla cuando AVFoundation parsea el EXT-X-DATERANGE.
        // Si esto no salta nunca, el player no reconoce el tag.
        observers.append(nc.addObserver(
            forName: AVPlayerInterstitialEventMonitor.eventsDidChangeNotification,
            object: monitor, queue: .main) { [weak self] _ in
                guard let self, let m = self.monitor else { return }
                self.scheduledCount = m.events.count
                self.add("agenda: \(m.events.count) interstitial(s)")
                for e in m.events {
                    self.add("  · \(e.identifier) @ \(e.date.map { "\($0)" } ?? "?")")
                }
        })

        observers.append(nc.addObserver(
            forName: AVPlayerInterstitialEventMonitor.currentEventDidChangeNotification,
            object: monitor, queue: .main) { [weak self] _ in
                guard let self, let m = self.monitor else { return }
                if let e = m.currentEvent {
                    self.inInterstitial = true
                    self.add("▶ ENTRA en \(e.identifier)")
                } else {
                    self.inInterstitial = false
                    self.add("◀ VUELVE al contenido")
                }
        })

        observers.append(nc.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                self?.add("ERROR: \(String(describing: err))")
        })

        add("cargando…")
        player.play()
    }

    private func add(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.insert(LogEntry(time: f.string(from: Date()), message: message), at: 0)
        if log.count > 200 { log.removeLast() }
    }
}
