# Plan de acción para estabilizar Nuvi

Este plan convierte la auditoría técnica en trabajo ejecutable. El objetivo no
es “mejorar todo”; es cerrar primero los riesgos que pueden bloquear al usuario,
romper la sesión de dictado o volver imposible probar regresiones.

## Ruta rápida

1. Corregir los **P0** de lifecycle y audio.
2. Agregar una suite mínima de tests para no arreglar a ciegas.
3. Cerrar los **P1** de cancelación, clipboard y hardening.
4. Optimizar Settings/render/audio donde hoy hay trabajo innecesario en MainActor.
5. Validar motores con probe reproducible y documentar resultados.

## Prioridades

| Prioridad | Objetivo | Resultado esperado |
|---|---|---|
| P0 | Evitar bloqueo post-error | El usuario puede reintentar después de errores o permisos denegados |
| P0 | Limpiar audio al fallar start | No quedan taps/streams colgados si AVAudioEngine falla |
| P1 | Evitar pegado tras cancelar | Cancelar nunca entrega texto tardío |
| P1 | Endurecer TextInjector | No crash por AX y no pérdida inesperada de clipboard |
| P1 | Crear tests base | `swift test` deja de fallar por ausencia de target |
| P2 | Reducir carga en UI/MainActor | Menos hops, menos I/O síncrono, menos recomputación |
| P2 | Mejorar arquitectura | Puertos claros y fakes para probar casos críticos |

## Fase 1 — P0: lifecycle y audio

### 1.1 Liberar sesión en todos los caminos terminales

- **Archivo**: `Sources/Nuvi/Application/DictationController.swift`
- **Problema**: `session` puede quedar no-nil después de errores o permiso de
  micrófono denegado.
- **Acción**:
  - Garantizar `session = nil` al terminar `runSession()`.
  - Mantener el mensaje `.error` visible sin bloquear un nuevo `start()`.
  - Revisar que `toggle()` desde `.error` pueda reintentar.
- **Aceptación**:
  - Un error de engine permite volver a iniciar dictado.
  - Micrófono denegado no deja la app trabada.
  - No se pierde el estado `.error` antes de que la UI pueda mostrarlo.

### 1.2 Corregir auto-hide de error en la píldora

- **Archivo**: `Sources/Nuvi/App/AppEnvironment.swift`
- **Problema**: el timer retorna justamente cuando el estado sigue en `.error`.
- **Acción**:
  - Invertir la condición o crear un flujo explícito para ocultar errores.
- **Aceptación**:
  - La píldora de error desaparece después del delay esperado.
  - No se oculta una sesión activa nueva por un timer viejo.

### 1.3 Hacer transaccional `AudioCaptureService.start()`

- **Archivo**: `Sources/Nuvi/Infrastructure/Audio/AudioCaptureService.swift`
- **Problema**: si `engine.start()` falla, el tap queda instalado.
- **Acción**:
  - Si `engine.start()` lanza error, remover tap, terminar continuation y limpiar
    referencias antes de propagar.
- **Aceptación**:
  - Un fallo de start no impide reintentar.
  - No hay tap duplicado después de error.

## Fase 2 — Tests mínimos antes de seguir

### 2.1 Crear target de tests

- **Archivos**:
  - `Package.swift`
  - `Tests/NuviTests/...`
- **Acción**:
  - Agregar target `NuviTests`.
  - Hacer importable lo necesario sin romper el ejecutable.
- **Aceptación**:
  - `swift test` ejecuta al menos una prueba real.

### 2.2 Tests de regresión obligatorios

- **Casos mínimos**:
  - `VocabularyStore.apply` con acentos, `ñ`, mayúsculas y substrings.
  - `ModesStore.effectiveMode` con modo activo y auto-activación por bundle ID.
  - `DictationController` permite reintentar después de error.
  - Cancelación no entrega texto.
- **Aceptación**:
  - Cada bug P0/P1 tiene una prueba que falla antes del fix o protege la
    conducta corregida.

## Fase 3 — P1: seguridad funcional y UX crítica

### 3.1 Evitar entrega de texto tras cancelación

- **Archivo**: `Sources/Nuvi/Application/DictationController.swift`
- **Acción**:
  - Chequear cancelación antes de `deliver()`.
  - Considerar un flag explícito `cancelRequested` si `Task.isCancelled` no cubre
    todos los caminos.
- **Aceptación**:
  - Presionar `Esc` nunca pega texto, aunque el engine emita un final tardío.

### 3.2 Endurecer `TextInjector`

- **Archivo**: `Sources/Nuvi/Infrastructure/Output/TextInjector.swift`
- **Acción**:
  - Reemplazar `as! AXUIElement` por cast seguro.
  - Restaurar clipboard también en ruta `axInsert`.
  - Decidir si el producto restaura clipboard completo o solo texto.
- **Tradeoff**:
  - Restaurar clipboard completo es más correcto, pero más código.
  - Restaurar solo texto es más simple, pero el setting debe decirlo con
    honestidad.
- **Aceptación**:
  - No hay crash por tipo AX inesperado.
  - El comportamiento del setting coincide con su nombre.

### 3.3 Corregir shortcut hardcodeado

- **Archivo**: `Sources/Nuvi/Presentation/MenuBar/StatusItemController.swift`
- **Acción**:
  - Usar `ShortcutsStore.shared.cycleMode.displayString`.
- **Aceptación**:
  - El menú refleja el shortcut configurado por el usuario.

## Fase 4 — P1/P2: performance, carga y MainActor

### 4.1 Reducir actualizaciones de nivel de audio

- **Archivo**: `Sources/Nuvi/Application/DictationController.swift`
- **Acción**:
  - Throttling/coalescing del nivel a 15–30 Hz.
- **Aceptación**:
  - El visualizador sigue fluido.
  - Se reduce la cantidad de hops al MainActor por segundo.

### 4.2 Cachear lista de apps para Modes

- **Archivo**: `Sources/Nuvi/Presentation/Settings/SettingsView.swift`
- **Acción**:
  - Mover `runningApps()` a un store/cache.
  - Actualizar por aparición de vista o notificaciones de workspace.
- **Aceptación**:
  - Escribir en `ModeEditor` no vuelve a consultar apps repetidamente.

### 4.3 Debounce de persistencia editable

- **Archivos**:
  - `VocabularyStore`
  - `ModesStore`
  - `FerrofluidSettingsStore`
  - `ShortcutsStore`
- **Acción**:
  - Debounce para sliders/text fields.
  - Persistir inmediatamente solo acciones críticas.
- **Aceptación**:
  - Menos escrituras repetidas a `UserDefaults`.

### 4.4 Sacar I/O de historial del MainActor

- **Archivo**: `Sources/Nuvi/Infrastructure/Settings/HistoryStore.swift`
- **Acción**:
  - Usar actor de persistencia o escritura async con snapshot.
- **Aceptación**:
  - UI no queda atada a `Data(contentsOf:)` ni `write(to:)`.

### 4.5 Controlar memoria en WhisperKit

- **Archivo**: `Sources/Nuvi/Infrastructure/Speech/WhisperKitEngine.swift`
- **Acción**:
  - Definir límite de duración o tamaño.
  - Evaluar streaming si la librería lo permite.
- **Aceptación**:
  - Dictados largos no crecen sin límite silenciosamente.

## Fase 5 — Validación de motores y observabilidad

### 5.1 Probar `SpeechAnalyzerEngine` con timeout

- **Archivo**: `Sources/Nuvi/Infrastructure/Speech/SpeechAnalyzerEngine.swift`
- **Acción**:
  - Ejecutar `--probe` con un audio controlado.
  - Agregar timeout para confirmar si `analyzer.start(inputSequence:)` cuelga.
- **Aceptación**:
  - El reporte dice “confirmado” o “descartado” con evidencia reproducible.

### 5.2 Validar errores de hotkeys

- **Archivo**: `Sources/Nuvi/Infrastructure/Hotkey/GlobalHotkey.swift`
- **Acción**:
  - Capturar `OSStatus` de `RegisterEventHotKey`.
  - Exponer fallo a Settings o logs claros.
- **Aceptación**:
  - Si un shortcut no registra, el usuario recibe feedback.

### 5.3 Mejorar logs de sesión

- **Archivos**:
  - `DictationController`
  - `AudioCaptureService`
  - engines de transcripción
- **Acción**:
  - Loggear inicio, stop, cancelación, engine elegido, errores y fallback.
- **Aceptación**:
  - Un bug de campo puede diagnosticarse sin adivinar.

## Fase 6 — Arquitectura para probar mejor

### 6.1 Extraer puerto de audio

- **Archivos**:
  - `DictationController`
  - `AudioCaptureService`
- **Acción**:
  - Crear protocolo `AudioCapturing`.
  - Inyectar fake en tests.
- **Aceptación**:
  - `DictationController` se prueba sin micrófono real.

### 6.2 Revisar dependencia WhisperKit

- **Archivo**: `Package.swift`
- **Problema**: la dependencia está documentada como opcional, pero el manifest
  la incluye siempre.
- **Acción**:
  - Elegir una verdad:
    - documentarla como dependencia incluida; o
    - separar configuración SpeechAnalyzer-only.
- **Aceptación**:
  - README, Package y build real no se contradicen.

## Orden sugerido de PRs

| PR | Alcance | Riesgo |
|---|---|---|
| PR 1 | Fix P0 lifecycle + audio cleanup | Bajo/medio |
| PR 2 | Test target + tests de regresión base | Medio |
| PR 3 | Cancelación + TextInjector hardening | Medio |
| PR 4 | Settings performance + debounce/cache | Medio |
| PR 5 | Engine probe + observabilidad | Medio |
| PR 6 | Arquitectura de audio + cleanup docs | Medio/alto |

## Checklist de cierre

- [x] `swift build` pasa.
- [x] `swift test` pasa.
- [x] `./scripts/build-app.sh release` pasa.
- [x] Error de micrófono/engine permite reintento.
- [x] Cancelación no pega texto.
- [x] Clipboard restore se comporta como promete la UI.
- [x] Menú muestra shortcuts reales.
- [x] Settings reduce trabajo repetitivo innecesario en MainActor.
- [x] `Report.md` queda actualizado con estado de implementación.
- [ ] Prueba manual/runtime con micrófono, permisos reales y app firmada.

## Siguiente paso recomendado

El siguiente paso recomendado ya no es otro refactor: es una **prueba manual
runtime** con permisos reales de macOS, dictado por micrófono y probe de motores.
La parte automatizable del plan base ya tiene build, tests y bundle verde.
