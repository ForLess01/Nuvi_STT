import XCTest
@testable import Nuvi

final class ModelsCatalogTests: XCTestCase {
    func testCatalogParsing() {
        let downloadService = ModelDownloadService.shared
        downloadService.loadCatalog()

        XCTAssertFalse(downloadService.catalog.isEmpty, "El catálogo de modelos no debería estar vacío")

        // Verificar que contiene el modelo tiny por defecto, mapeado a WhisperKit.
        let tinyModel = downloadService.catalog.first(where: { $0.id == "openai_whisper-tiny" })
        XCTAssertNotNil(tinyModel, "El catálogo debería contener el modelo openai_whisper-tiny")
        XCTAssertEqual(tinyModel?.engine, .whisperKit, "Whisper Tiny debería pertenecer al engine WhisperKit")
        XCTAssertEqual(tinyModel?.icon, "bolt.horizontal.fill", "El icono de Whisper Tiny debería ser bolt.horizontal.fill")

        // Los modelos community placeholder fueron removidos del catálogo.
        XCTAssertNil(downloadService.catalog.first(where: { $0.id == "community_whisper-es-fine" }),
                     "El modelo placeholder community_whisper-es-fine no debería existir")
        XCTAssertNil(downloadService.catalog.first(where: { $0.id == "community_whisper-clinical" }),
                     "El modelo placeholder community_whisper-clinical no debería existir")

        // El catálogo debe ofrecer ambas familias de engine.
        let whisperModels = downloadService.catalog.filter { $0.engine == .whisperKit }
        let parakeetModels = downloadService.catalog.filter { $0.engine == .parakeet }
        XCTAssertFalse(whisperModels.isEmpty, "Debe haber al menos un modelo WhisperKit")
        XCTAssertFalse(parakeetModels.isEmpty, "Debe haber al menos un modelo Parakeet")

        // Métricas y campos comunes válidos para todos los modelos.
        for model in downloadService.catalog {
            XCTAssertTrue(model.accuracy > 0.0 && model.accuracy <= 1.0, "La métrica de precisión de \(model.name) debe estar en el rango de (0, 1.0]")
            XCTAssertTrue(model.speed > 0.0 && model.speed <= 1.0, "La métrica de velocidad de \(model.name) debe estar en el rango de (0, 1.0]")
            XCTAssertFalse(model.icon.isEmpty, "El identificador de icono de \(model.name) no debe estar vacío")
            XCTAssertTrue(model.sizeBytes > 0, "El tamaño del archivo de \(model.name) debe ser mayor que 0")
            XCTAssertTrue(model.ramBytes > 0, "La huella de RAM estimada de \(model.name) debe ser mayor que 0")
        }

        // WhisperKit descarga vía su propia API por nombre de variante (el id),
        // no por URL directa. El id debe ser una variante válida sin espacios.
        for model in whisperModels {
            XCTAssertFalse(model.id.isEmpty, "El modelo WhisperKit debe tener un id de variante")
            XCTAssertFalse(model.id.contains(" "), "El id de variante \(model.id) no debe tener espacios")
        }

        // Parakeet se gestiona vía FluidAudio: sin URL directa, pero con versión declarada.
        for model in parakeetModels {
            XCTAssertNil(model.downloadUrl, "El modelo Parakeet \(model.name) no usa downloadUrl directo")
            XCTAssertNotNil(model.parakeetVersion, "El modelo Parakeet \(model.name) debe declarar parakeetVersion (v2/v3)")
        }
    }
}
