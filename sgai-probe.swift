//  Sonda AVFoundation para el PoC SGAI.
//
//  Se compila y ejecuta en macOS (por ejemplo en un runner de GitHub Actions),
//  así que permite probar el player NATIVO sin tener un Mac ni un iPad.
//
//  Lo que responde, que es lo que no se ve desde el servidor:
//    1. ¿AVFoundation PARSEA nuestro EXT-X-DATERANGE?  -> se puebla la agenda
//    2. ¿Lo EJECUTA?                                   -> currentEvent cambia
//  Si (1) no ocurre, el problema está en el tag. Si ocurre (1) pero no (2), está
//  entre el parseo y la resolución del X-ASSET-LIST.

import Foundation
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 2, let url = URL(string: args[1]) else {
    FileHandle.standardError.write("uso: sgai-probe <url> [segundos]\n".data(using: .utf8)!)
    exit(2)
}
let seconds = args.count >= 3 ? (Double(args[2]) ?? 120) : 120

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

let player = AVPlayer(url: url)
let monitor = AVPlayerInterstitialEventMonitor(primaryPlayer: player)
let nc = NotificationCenter.default

var sawSchedule = false
var sawInterstitialStart = false
var scheduleMax = 0

nc.addObserver(forName: AVPlayerInterstitialEventMonitor.eventsDidChangeNotification,
               object: monitor, queue: .main) { _ in
    let events = monitor.events
    scheduleMax = max(scheduleMax, events.count)
    if !events.isEmpty { sawSchedule = true }
    log("AGENDA: \(events.count) interstitial(s)")
    for e in events {
        log("   · id=\(e.identifier) fecha=\(e.date.map { "\($0)" } ?? "?") "
            + "plantillas=\(e.templateItems.count) reanudar=\(e.resumptionOffset.seconds)")
    }
}

nc.addObserver(forName: AVPlayerInterstitialEventMonitor.currentEventDidChangeNotification,
               object: monitor, queue: .main) { _ in
    if let e = monitor.currentEvent {
        sawInterstitialStart = true
        log("ENTRA en interstitial: \(e.identifier)")
    } else {
        log("VUELVE al contenido primario")
    }
}

nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
               object: nil, queue: .main) { note in
    log("ERROR: \(String(describing: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]))")
}

// Estado del item primario: sin esto, un fallo de carga pasa desapercibido.
var statusObs: NSKeyValueObservation?
statusObs = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
    switch item.status {
    case .readyToPlay: log("item listo para reproducir")
    case .failed:      log("item FALLÓ: \(String(describing: item.error))")
    default:           break
    }
}

log("cargando \(url.absoluteString)")
log("sondeando durante \(Int(seconds)) s…")
player.play()

var ticks = 0
let timer = Timer(timeInterval: 5, repeats: true) { _ in
    ticks += 5
    log("t=\(ticks)s  currentTime=\(String(format: "%.1f", player.currentTime().seconds))  "
        + "rate=\(player.rate)")
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
timer.invalidate()
statusObs?.invalidate()

print("")
print("===== RESULTADO =====")
print("AVFoundation parseó el DATERANGE : \(sawSchedule ? "SÍ" : "NO")  (máximo en agenda: \(scheduleMax))")
print("Ejecutó algún interstitial       : \(sawInterstitialStart ? "SÍ" : "NO")")
print("=====================")

// Sale con error sólo si ni siquiera parseó: eso es el fallo duro.
exit(sawSchedule ? 0 : 1)
