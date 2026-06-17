# Reporte Técnico de Auditoría: Nuvi

Auditoría actualizada el **2026-06-16**. Esta versión audita también la
auditoría anterior: separa hechos comprobados, riesgos razonables y puntos que
requieren reproducción runtime.

## 1. Verificación ejecutada

Comandos ejecutados:

```bash
swift build
swift build -Xswiftc -warn-concurrency -Xswiftc -strict-concurrency=targeted
./scripts/build-app.sh release
swift test
```

Resultado:

- `swift build` ✅
- build con warnings de concurrencia targeted ✅
- `./scripts/build-app.sh release` ✅
- `swift test` ✅ 5 tests de regresión

## 1.1 Estado de implementación

Después de esta auditoría se implementó el primer ciclo de estabilización:

- P0 lifecycle de `DictationController`: **resuelto**
- Cleanup transaccional de `AudioCaptureService.start()`: **resuelto**
- Auto-hide de error en la píldora: **resuelto**
- Target `NuviTests`: **creado**
- Tests base de vocabulario, modos y controller: **creados**
- Hardening inicial de `TextInjector`: **resuelto**
- Shortcut dinámico en menú: **resuelto**
- Throttling de nivel de audio: **implementado**
- Cache de apps en Settings/Modes: **implementado**
- Límite de memoria para WhisperKit batch: **implementado**
- Timeout de probe para motores: **implementado**

## 2. Hallazgos críticos confirmados

### 2.1 La app puede quedar bloqueada después de un error de dictado

- **Ubicación**: `Sources/Nuvi/Application/DictationController.swift`
- **Evidencia**:
  - `start()` impide iniciar si `session != nil`.
  - En `runSession()`, los caminos de error (`state = .error(...)`) no limpian
    `session`.
  - El caso de permiso de micrófono denegado también retorna sin llamar a
    `reset()`.
- **Impacto**: crítico. Después de un error o permiso denegado, `toggle()` entra
  por `.error`, llama `start()`, pero `start()` sale por `guard session == nil`.
  El usuario queda sin poder reintentar desde la UI.
- **Recomendación**: usar `defer` o limpieza explícita para dejar
  `session = nil` en todos los caminos terminales. No necesariamente limpiar el
  mensaje de error inmediatamente; sí liberar la sesión.

### 2.2 El mensaje de error de la píldora no se auto-oculta

- **Ubicación**: `Sources/Nuvi/App/AppEnvironment.swift`
- **Evidencia**:
  - El timer hace `if case .error = self.controller.state { return }`.
  - Es decir, si todavía está en error, retorna y no oculta.
- **Impacto**: medio-alto. Un error queda pegado en pantalla indefinidamente.
- **Recomendación**: invertir la condición o introducir un estado/error
  descartable con transición clara.

### 2.3 `AudioCaptureService.start()` puede dejar un tap instalado si falla

- **Ubicación**: `Sources/Nuvi/Infrastructure/Audio/AudioCaptureService.swift`
- **Evidencia**:
  - Primero instala el tap.
  - Luego llama `try engine.start()`.
  - Si `engine.start()` falla, no hay cleanup del tap ni de la continuación.
- **Impacto**: alto. Un reintento puede fallar con tap duplicado o estado interno
  inconsistente.
- **Recomendación**: envolver `engine.start()` con `do/catch`, remover el tap y
  terminar la continuación antes de propagar el error.

## 3. Bugs funcionales confirmados

### 3.1 Restauración de clipboard incompleta

- **Ubicación**: `Sources/Nuvi/Infrastructure/Output/TextInjector.swift`
- **Evidencia**:
  - Solo guarda `pasteboard.string(forType: .string)`.
  - Si el clipboard contenía imagen, archivo, rich text u otro tipo, se pierde.
  - Si se usa `axInsert`, el clipboard ya fue reemplazado por el texto y no se
    restaura.
- **Impacto**: alto. El setting “Restore clipboard” promete más de lo que
  realmente cumple.
- **Recomendación**: capturar/restaurar `NSPasteboardItem` completo o renombrar
  el setting a “Restore previous text clipboard”.

### 3.2 Crash posible por cast forzado de Accessibility

- **Ubicación**: `Sources/Nuvi/Infrastructure/Output/TextInjector.swift`
- **Evidencia**: `return (raw as! AXUIElement)`
- **Impacto**: medio-alto. Si Accessibility devuelve un tipo inesperado, la app
  crashea.
- **Recomendación**: usar cast seguro y devolver `nil` si no es `AXUIElement`.

### 3.3 El menú muestra un shortcut hardcodeado

- **Ubicación**: `Sources/Nuvi/Presentation/MenuBar/StatusItemController.swift`
- **Evidencia**: `"Cycle: ⌥⇧K"` está fijo, aunque el usuario puede reconfigurar
  el shortcut.
- **Impacto**: bajo-medio. UI inconsistente.
- **Recomendación**: usar `ShortcutsStore.shared.cycleMode.displayString`.

### 3.4 Reemplazos de vocabulario con límites Unicode frágiles

- **Ubicación**: `Sources/Nuvi/Infrastructure/Settings/VocabularyStore.swift`
- **Evidencia**: usa `\b...\b` con `NSRegularExpression`.
- **Impacto**: medio. Riesgo de falsos negativos o falsos positivos con
  acentos, `ñ`, símbolos y palabras no ASCII.
- **Recomendación**: implementar límites por `CharacterSet`/tokenización Unicode
  y cubrirlo con tests.

## 4. Problemas de rendimiento, carga y UX

### 4.1 Actualizaciones de nivel de audio crean tareas al MainActor por buffer

- **Ubicación**: `Sources/Nuvi/Application/DictationController.swift`
- **Evidencia**:
  - `AudioCaptureService` emite nivel desde el audio tap.
  - Cada emisión crea `Task { @MainActor in self?.level = level }`.
- **Impacto**: medio-alto. Con buffer de 1024 frames, esto puede generar decenas
  de hops al MainActor por segundo durante grabación.
- **Recomendación**: throttling/coalescing a 15–30 Hz o store atómico leído por
  el renderer.

### 4.2 `ModeEditor` consulta apps en cada inicialización de vista

- **Ubicación**: `Sources/Nuvi/Presentation/Settings/SettingsView.swift`
- **Evidencia**:
  - `private let apps = runningApps()`
  - `runningApps()` consulta `NSWorkspace.shared.runningApplications`.
- **Impacto**: medio. En SwiftUI, recrear vistas puede disparar consultas
  repetidas en MainActor, especialmente al editar campos.
- **Recomendación**: moverlo a un store/cache y actualizar con notificaciones de
  workspace.

### 4.3 Persistencia sin debounce en settings editables

- **Ubicaciones**:
  - `VocabularyStore`
  - `ModesStore`
  - `FerrofluidSettingsStore`
  - `ShortcutsStore`
- **Evidencia**: varios `didSet { save() }` escriben a `UserDefaults`.
- **Impacto**: medio. Sliders y text fields pueden escribir por cada cambio.
- **Recomendación**: debounce para controles de alta frecuencia y batch-save al
  cerrar/confirmar.

### 4.4 Historial escribe JSON síncrono en MainActor

- **Ubicación**: `Sources/Nuvi/Infrastructure/Settings/HistoryStore.swift`
- **Evidencia**:
  - `Data(contentsOf:)` en load.
  - `data.write(to:options:)` en save.
  - Store marcado `@MainActor`.
- **Impacto**: medio. Con 500 entradas no es grave hoy, pero es I/O síncrono en
  UI.
- **Recomendación**: actor de persistencia o escritura async con snapshot.

### 4.5 WhisperKit acumula todo el audio en memoria

- **Ubicación**: `Sources/Nuvi/Infrastructure/Speech/WhisperKitEngine.swift`
- **Evidencia**: `var samples: [Float] = []` y append de todo el stream.
- **Impacto**: medio. Dictados largos crecen sin límite hasta finalizar.
- **Recomendación**: límite de duración, streaming si WhisperKit lo permite, o
  spool temporal.

### 4.6 Shader Metal compilado en runtime

- **Ubicación**: `Sources/Nuvi/Presentation/Ferrofluid/FerrofluidRenderer.swift`
- **Evidencia**: `device.makeLibrary(source: FerrofluidShaderSource, options: nil)`.
- **Impacto**: medio. Puede producir stutter al crear el renderer por primera
  vez.
- **Recomendación**: precompilar shader en bundle o calentar renderer al iniciar.

### 4.7 La píldora no reancla al crecer

- **Ubicación**: `Sources/Nuvi/Presentation/Pill/PillWindowController.swift`
- **Evidencia**:
  - `positionTopLeft()` solo se llama en `show()`.
  - `resizeToContent()` cambia el tamaño manteniendo el origen.
- **Impacto**: medio. Al crecer en altura, una ventana con origen inferior puede
  moverse visualmente hacia arriba y perder el anclaje esperado.
- **Recomendación**: recalcular origen luego de resize para mantener top-left.

## 5. Riesgos de concurrencia / lifecycle

### 5.1 `SpeechAnalyzerEngine` tiene orden de arranque sospechoso

- **Ubicación**: `Sources/Nuvi/Infrastructure/Speech/SpeechAnalyzerEngine.swift`
- **Evidencia**:
  - Crea `inputStream`.
  - Llama `try await analyzer.start(inputSequence: inputStream)`.
  - Recién después crea el pump que alimenta el stream.
- **Impacto potencial**: crítico si `start` espera input o queda suspendido.
- **Estado**: riesgo fuerte, pendiente de reproducción con `--probe`.
- **Recomendación**: probar con timeout. Si cuelga, arrancar pump/consumo de
  resultados concurrentemente antes de esperar `start`.

### 5.2 Cancelación puede terminar entregando texto tardío

- **Ubicación**: `Sources/Nuvi/Application/DictationController.swift`
- **Evidencia**: después del `for try await event`, llama `await deliver()` sin
  `Task.isCancelled` explícito.
- **Impacto potencial**: medio-alto. Un resultado final tardío podría pegarse
  después de cancelar.
- **Estado**: plausible; requiere test con fake engine controlado.
- **Recomendación**: chequear cancelación antes de `deliver()` y antes de mutar
  estado final.

### 5.3 `@unchecked Sendable` usado como escape hatch

- **Ubicaciones**:
  - `AudioCaptureService`
  - `SpeechAnalyzerEngine`
  - `HybridTranscriptionEngine`
  - `WhisperKitEngine`
  - `SettingsStore`
- **Impacto**: medio. El build targeted no alerta, pero el target compila en
  Swift 5 language mode; eso reduce la garantía de concurrencia real.
- **Recomendación**: aislar por actor donde tenga sentido o documentar invariants
  de thread-safety por tipo.

### 5.4 Hotkeys no validan errores de registro

- **Ubicación**: `Sources/Nuvi/Infrastructure/Hotkey/GlobalHotkey.swift`
- **Evidencia**: `RegisterEventHotKey(...)` ignora `OSStatus`.
- **Impacto**: medio. Si el shortcut está ocupado o falla el registro, la UI no
  se entera.
- **Recomendación**: devolver/registrar error y reflejarlo en Settings.

## 6. Problemas de arquitectura y mantenibilidad

### 6.1 `AudioCaptureService` no es puerto pese a lo que sugiere el comentario

- **Ubicación**: `DictationController` y `AudioCaptureService`
- **Evidencia**: `DictationController` depende del tipo concreto
  `AudioCaptureService`.
- **Impacto**: medio. Complica tests de `DictationController`.
- **Recomendación**: extraer protocolo `AudioCapturing` para poder usar fakes.

### 6.2 Dependencia “opcional” no es realmente opcional en `Package.swift`

- **Ubicación**: `Package.swift`
- **Evidencia**:
  - `argmax-oss-swift` se declara siempre.
  - El target depende siempre de `.product(name: "WhisperKit", ...)`.
- **Impacto**: medio. La app no es “SpeechAnalyzer only” sin editar el manifest.
- **Recomendación**: documentarlo como dependencia incluida o separar targets /
  flags de build.

### 6.3 No hay tests para los puntos más delicados

- **Estado**: resuelto parcialmente.
- **Evidencia**: `swift test` ejecuta 5 tests.
- **Cobertura actual**:
  - `VocabularyStore.apply`
  - `ModesStore.effectiveMode`
  - `DictationController` con fake audio + fake engine
  - cancelación sin entrega de texto
- **Pendiente**: ampliar cobertura sobre `TextInjector`, hotkeys, stores y probe.

## 7. Qué corregir primero

1. **Hecho**: liberar `session` en errores de `DictationController`.
2. **Hecho**: cleanup de `AudioCaptureService.start()` si falla `engine.start()`.
3. **Hecho**: test/fix de cancelación para que nunca pegue texto cancelado.
4. **Hecho**: hardening inicial de `TextInjector` y restauración de clipboard.
5. **Hecho**: timeout de `SpeechAnalyzerEngine --probe`.
6. **Hecho**: debounce/caching inicial en Settings y stores.
7. **Hecho**: suite de tests base.
8. **Pendiente**: pruebas runtime reales con micrófono/SpeechAnalyzer/WhisperKit
   en una sesión de app firmada.

## 8. Conclusión

La auditoría anterior hizo bien en corregir documentación, pero se quedó corta
en lifecycle real. El bug más grave no es de rendimiento: es que un error puede
dejar la app sin posibilidad de reintentar porque `session` queda ocupada.

El proyecto compila y empaqueta, pero todavía está débil en pruebas,
observabilidad de errores y manejo de estados terminales. Antes de seguir
sumando features, conviene cerrar los P0/P1.
