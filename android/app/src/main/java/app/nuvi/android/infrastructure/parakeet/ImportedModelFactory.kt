package app.nuvi.android.infrastructure.parakeet

/** Enforces null asset ownership for models imported into app-private filesystem storage. */
object ImportedModelFactory {
    fun <A, C, R> create(config: C, constructor: (A?, C) -> R): R = constructor(null, config)
}
