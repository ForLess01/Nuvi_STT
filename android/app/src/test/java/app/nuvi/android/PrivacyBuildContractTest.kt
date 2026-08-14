package app.nuvi.android

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PrivacyBuildContractTest {
    @Test fun manifestHasNoInternetOrAccessibilityService() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertFalse(manifest.contains("android.permission.INTERNET"))
        assertFalse(manifest.contains("AccessibilityService"))
        val permissions = Regex("<uses-permission android:name=\"([^\"]+)\"")
            .findAll(manifest).map { it.groupValues[1] }.toSet()
        assertEquals(setOf(
            "android.permission.RECORD_AUDIO",
            "android.permission.FOREGROUND_SERVICE",
            "android.permission.FOREGROUND_SERVICE_DATA_SYNC"
        ), permissions)
        assertTrue(manifest.contains("android:process=\":model_import\""))
        assertTrue(manifest.contains("android:process=\":asr\""))
        assertTrue(manifest.contains(".infrastructure.asr.AsrRuntimeService"))
        assertTrue(manifest.contains("android:exported=\"false\""))
    }

}
