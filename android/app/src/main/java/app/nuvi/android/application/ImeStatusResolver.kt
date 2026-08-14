package app.nuvi.android.application

object ImeStatusResolver {
    enum class Check { YES, NO, UNKNOWN }
    data class Snapshot(val enabled: Check, val selected: Check)

    fun resolve(
        applicationPackage: String,
        enabledPackages: Result<List<String>>,
        currentPackage: Result<String?>?
    ): Snapshot {
        val enabled = enabledPackages.fold(
            onSuccess = { if (applicationPackage in it) Check.YES else Check.NO },
            onFailure = { Check.UNKNOWN }
        )
        val selected = currentPackage?.fold(
            onSuccess = { current -> if (current == null) Check.UNKNOWN else if (current == applicationPackage) Check.YES else Check.NO },
            onFailure = { Check.UNKNOWN }
        ) ?: Check.UNKNOWN
        return Snapshot(enabled, selected)
    }
}
