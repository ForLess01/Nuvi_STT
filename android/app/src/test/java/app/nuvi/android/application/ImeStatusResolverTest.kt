package app.nuvi.android.application

import app.nuvi.android.application.ImeStatusResolver.Check
import org.junit.Assert.assertEquals
import org.junit.Test

class ImeStatusResolverTest {
    @Test fun resolvesEnabledAndCurrentFromPublicApiResults() {
        assertEquals(
            ImeStatusResolver.Snapshot(Check.YES, Check.YES),
            ImeStatusResolver.resolve("app.nuvi", Result.success(listOf("other", "app.nuvi")), Result.success("app.nuvi"))
        )
    }

    @Test fun resolvesDefiniteDisabledAndDifferentCurrentIme() {
        assertEquals(
            ImeStatusResolver.Snapshot(Check.NO, Check.NO),
            ImeStatusResolver.resolve("app.nuvi", Result.success(listOf("other")), Result.success("other"))
        )
    }

    @Test fun queryFailuresAndUnsupportedCurrentAreUnknownWithoutLying() {
        assertEquals(
            ImeStatusResolver.Snapshot(Check.UNKNOWN, Check.UNKNOWN),
            ImeStatusResolver.resolve("app.nuvi", Result.failure(SecurityException("blocked")), null)
        )
    }

    @Test fun nullCurrentResultIsUnknown() {
        assertEquals(Check.UNKNOWN, ImeStatusResolver.resolve("app.nuvi", Result.success(listOf("app.nuvi")), Result.success(null)).selected)
    }
}
