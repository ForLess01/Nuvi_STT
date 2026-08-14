package app.nuvi.android.infrastructure.asr

import app.nuvi.android.domain.ModelFamily
import java.io.File

object EngineCachePolicy {
    fun canReuse(
        cachedFamily: ModelFamily,
        cachedRoot: File,
        cachedVersion: String,
        requestedFamily: ModelFamily,
        requestedRoot: File,
        requestedVersion: String
    ): Boolean = cachedFamily == requestedFamily &&
        cachedRoot.absoluteFile.normalize() == requestedRoot.absoluteFile.normalize() &&
        cachedVersion == requestedVersion
}
