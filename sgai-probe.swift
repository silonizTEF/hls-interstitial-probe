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

// Reenganche: en un reemplazo, el contenido primario tiene que retomar
// X-RESUME-OFFSET segundos después de donde salió. Es LA medida que distingue
// "ejecuta el interstitial" de "lo ejecuta bien": un player puede entrar en el
// anuncio y volver al sitio equivocado, y desde el servidor eso no se ve.
//
// Mientras el interstitial está en curso el player primario se queda parado en
// el punto de salida, así que basta con anotar su currentTime al entrar y al
// volver.
struct Break {
    let id: String
    let sale: Double
    var vuelve: Double?
}
var breaks: [Break] = []

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
    let ahora = player.currentTime().seconds
    if let e = monitor.currentEvent {
        sawInterstitialStart = true
        breaks.append(Break(id: e.identifier, sale: ahora, vuelve: nil))
        log("ENTRA en interstitial: \(e.identifier)  (primario en \(String(format: "%.2f", ahora)))")
    } else {
        // El primario tarda un instante en recolocarse tras el interstitial, así
        // que se lee un poco después: leerlo aquí mismo da todavía el punto de
        // salida y el reenganche saldría 0.
        //
        // Pero esa espera hay que DESCONTARLA: durante ella la reproducción
        // avanza al ritmo del reloj, y si no se resta el reenganche sale ~1 s
        // largo. La primera versión de esto daba +17,0 s donde el player hacía
        // +16,0 y lo marcaba como fallo del player.
        let tEvento = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let vuelta = player.currentTime().seconds
            let transcurrido = Date().timeIntervalSince(tEvento)
            if let i = breaks.lastIndex(where: { $0.vuelve == nil }) {
                breaks[i].vuelve = vuelta - transcurrido
                let d = breaks[i].vuelve! - breaks[i].sale
                log("VUELVE al contenido primario en \(String(format: "%.2f", vuelta))"
                    + "  -> reenganche +\(String(format: "%.2f", d))s")
            } else {
                log("VUELVE al contenido primario en \(String(format: "%.2f", vuelta))")
            }
        }
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

// Reenganche esperado, para poder juzgar sin mirar a ojo. Se pasa como tercer
// argumento; 0 significa "no lo compruebes" (p.ej. con el stream de Apple, que
// es aditivo).
let esperado = args.count >= 4 ? (Double(args[3]) ?? 0) : 0

print("")
print("===== RESULTADO =====")
print("AVFoundation parseó el DATERANGE : \(sawSchedule ? "SÍ" : "NO")  (máximo en agenda: \(scheduleMax))")
print("Ejecutó algún interstitial       : \(sawInterstitialStart ? "SÍ" : "NO")")
print("Interstitials ejecutados         : \(breaks.count)")

var reenganchesOk = 0
let completos = breaks.filter { $0.vuelve != nil }
for b in completos {
    let d = b.vuelve! - b.sale
    let ok = esperado > 0 && abs(d - esperado) < 1.0
    if ok { reenganchesOk += 1 }
    print("  \(b.id): sale en \(String(format: "%.2f", b.sale))"
        + " -> vuelve en \(String(format: "%.2f", b.vuelve!))"
        + "  (+\(String(format: "%.2f", d))s)"
        + (esperado > 0 ? (ok ? "  ok" : "  MAL, se esperaba +\(esperado)") : ""))
}
if esperado > 0 {
    print("Reenganches correctos            : \(reenganchesOk)/\(completos.count)")
}
print("=====================")

// Sale con error sólo si ni siquiera parseó: eso es el fallo duro. Lo demás se
// interpreta leyendo, porque "no se ejecutó" puede ser legítimo según el stream.
exit(sawSchedule ? 0 : 1)
