package app.nuvi.android.domain

import android.text.InputType
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureEditorClassifierTest {
    @Test fun classifiesTextPasswordsAsSecure() {
        val variants = listOf(
            InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
        )
        variants.forEach { variation ->
            assertTrue(SecureEditorClassifier.isSecureInputType(InputType.TYPE_CLASS_TEXT or variation))
        }
    }

    @Test fun classifiesNumericPasswordsAsSecure() {
        assertTrue(SecureEditorClassifier.isSecureInputType(
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        ))
    }

    @Test fun acceptsNormalTextAndNumbers() {
        assertFalse(SecureEditorClassifier.isSecureInputType(InputType.TYPE_CLASS_TEXT))
        assertFalse(SecureEditorClassifier.isSecureInputType(InputType.TYPE_CLASS_NUMBER))
    }
}
