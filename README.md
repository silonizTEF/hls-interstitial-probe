# Sonda de HLS Interstitials para AVFoundation

Utilidad mínima para responder a una pregunta que no se puede contestar desde el
servidor: **¿el reproductor nativo de Apple reconoce y ejecuta un
`EXT-X-DATERANGE` de interstitial?**

## Por qué existe

Safari en iOS **no** ejecuta HLS Interstitials. Comprobado contra el stream de
referencia de Apple (`developer.apple.com/streaming/examples` → *TV+ Trailer
Interstitial*): en un iPhone con iOS 26 dura 1m38s — el contenido primario solo —
en vez de los 2m16s que duraría con sus tres interstitials insertados. Apple lo
documenta: *"If Interstitials are not supported, only primary content is played"*.

Son una funcionalidad de **AVFoundation**, y probarla requiere un Mac o un iPad
(Swift Playgrounds es solo para iPad). Este repo evita ambos: la sonda se compila
y ejecuta en un **runner macOS de GitHub Actions**, que es gratis en repositorios
públicos.

## Qué mide

`AVPlayerInterstitialEventMonitor` expone la agenda de interstitials que el player
extrae del manifiesto y notifica al entrar y salir de cada uno. Eso separa dos
fallos que desde fuera son indistinguibles:

| Señal | Significado |
|---|---|
| `AGENDA: N interstitial(s)` | AVFoundation **parseó** el `EXT-X-DATERANGE` |
| `ENTRA en interstitial` | Además lo **ejecuta** |
| agenda vacía | El problema está en el propio tag |
| agenda llena pero nunca entra | El problema está entre el parseo y la resolución del `X-ASSET-LIST` |

## Uso

Actions → **Sonda AVFoundation** → *Run workflow*. Por defecto sondea el stream de
referencia de Apple, que es la calibración: si ahí no detecta nada, la medida no
vale para nada y hay que arreglar la sonda antes de mirar otros streams.

Para sondear otro stream, pásale su URL en el campo `url`. Tiene que ser
alcanzable desde internet.

## Estado

La sonda **no se ha podido compilar ni probar en local** — se escribió en Linux,
sin macOS ni Xcode. La primera ejecución puede fallar por algo tonto de
compilación.
