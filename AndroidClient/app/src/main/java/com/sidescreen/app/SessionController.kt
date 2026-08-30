package com.sidescreen.app

/**
 * The single Android session truth.
 *
 * Transport readiness and the local USB checklist are deliberately not the
 * same thing.  A session becomes Streaming only after the current generation
 * has negotiated a valid display, started a decoder, and reached the render
 * path.  Control-channel health is a capability of that stream, not stream
 * liveness.
 */
class SessionController {
    enum class ControlHealth {
        UNKNOWN,
        HEALTHY,
        DEGRADED,
    }

    data class Details(
        val generation: Long,
        val mode: ConnectionMode,
        val protocolReady: Boolean,
        val displayConfigured: Boolean,
        val decoderReady: Boolean,
        val firstFrameDecoded: Boolean,
        val firstFrameRendered: Boolean,
        val control: ControlHealth,
    )

    sealed interface State {
        object Idle : State

        data class Preflight(val advisories: List<String>) : State

        data class Connecting(
            val generation: Long,
            val mode: ConnectionMode,
        ) : State

        data class Negotiating(val details: Details) : State

        data class WaitingForFirstFrame(val details: Details) : State

        data class Streaming(val details: Details) : State

        data class Disconnecting(
            val generation: Long,
            val reason: String,
        ) : State

        data class Disconnected(val reason: String) : State

        data class Failed(
            val reason: String,
            val retryable: Boolean = true,
        ) : State
    }

    @Volatile
    var state: State = State.Idle
        private set

    val currentGeneration: Long
        get() = synchronized(lock) { generationValue }

    /** Called after every authoritative transition. */
    var onStateChanged: ((State) -> Unit)? = null

    private val lock = Any()
    private var generationValue = 0L
    private var activeDetails: Details? = null

    fun begin(mode: ConnectionMode): Long {
        val next = synchronized(lock) {
            generationValue += 1
            val details = Details(
                generation = generationValue,
                mode = mode,
                protocolReady = false,
                displayConfigured = false,
                decoderReady = false,
                firstFrameDecoded = false,
                firstFrameRendered = false,
                control = ControlHealth.UNKNOWN,
            )
            activeDetails = details
            State.Connecting(generationValue, mode)
        }
        publish(next)
        return generationValue
    }

    fun transportConnected(generation: Long): Boolean = update(generation) { it }

    /** A codec-selected message proves protocol negotiation; legacy display
     *  configuration can also establish the minimum compatible protocol. */
    fun protocolNegotiated(generation: Long): Boolean = update(generation) {
        it.copy(protocolReady = true)
    }

    fun displayConfigured(
        generation: Long,
        legacyProtocolAccepted: Boolean = false,
    ): Boolean = update(generation) {
        it.copy(
            displayConfigured = true,
            protocolReady = it.protocolReady || legacyProtocolAccepted,
        )
    }

    fun decoderStarted(generation: Long): Boolean = update(generation) {
        it.copy(decoderReady = true)
    }

    fun frameDecoded(generation: Long): Boolean = update(generation) {
        it.copy(firstFrameDecoded = true)
    }

    fun surfaceRendered(generation: Long): Boolean = update(generation) {
        it.copy(
            firstFrameDecoded = true,
            firstFrameRendered = true,
        )
    }

    fun controlHealthy(generation: Long, healthy: Boolean): Boolean = update(generation) {
        it.copy(control = if (healthy) ControlHealth.HEALTHY else ControlHealth.DEGRADED)
    }

    fun fail(generation: Long, reason: String): Boolean {
        val next = synchronized(lock) {
            if (!isCurrentLocked(generation)) return false
            activeDetails = null
            State.Failed(reason = reason)
        }
        publish(next)
        return true
    }

    /** Idempotent user/lifecycle teardown. Invalidates the old generation
     * before any callbacks from its sockets or decoder can run. */
    fun disconnect(reason: String = "user requested disconnect"): Boolean {
        val transitions = synchronized(lock) {
            val oldGeneration = currentGeneration
            generationValue += 1
            activeDetails = null
            listOf(
                State.Disconnecting(oldGeneration, reason),
                State.Disconnected(reason),
            )
        }
        transitions.forEach(::publish)
        return true
    }

    /** A transport failure is terminal for the current generation, but does
     * not turn advisory preflight into a false "not ready" state. */
    fun transportLost(
        generation: Long,
        reason: String = "video transport closed",
    ): Boolean {
        val next = synchronized(lock) {
            if (!isCurrentLocked(generation)) return false
            generationValue += 1
            activeDetails = null
            State.Disconnected(reason)
        }
        publish(next)
        return true
    }

    fun setPreflight(advisories: List<String>) {
        val next = synchronized(lock) {
            if (activeDetails != null || state is State.Failed) return
            State.Preflight(advisories.distinct())
        }
        publish(next)
    }

    fun isCurrent(generation: Long): Boolean = synchronized(lock) {
        isCurrentLocked(generation)
    }

    fun canInitializeDecoder(generation: Long): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        details.generation == generation &&
            details.protocolReady &&
            details.displayConfigured
    }

    fun hasTransport(): Boolean = synchronized(lock) {
        activeDetails?.let { it.protocolReady || it.displayConfigured || it.decoderReady || it.firstFrameDecoded } == true ||
            state is State.Connecting || state is State.Negotiating ||
            state is State.WaitingForFirstFrame || state is State.Streaming
    }

    fun isStreaming(generation: Long? = null): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        state is State.Streaming && (generation == null || details.generation == generation)
    }

    fun shouldForwardTouch(): Boolean = synchronized(lock) {
        state is State.Streaming
    }

    fun ownsBrightness(generation: Long): Boolean = synchronized(lock) {
        val details = activeDetails ?: return false
        details.generation == generation && state is State.Streaming
    }

    private fun update(
        generation: Long,
        transform: (Details) -> Details,
    ): Boolean {
        val next = synchronized(lock) {
            val current = activeDetails ?: return false
            if (current.generation != generation) return false
            val updated = transform(current)
            activeDetails = updated
            stateFor(updated)
        }
        publish(next)
        return true
    }

    private fun isCurrentLocked(generation: Long): Boolean =
        activeDetails?.generation == generation && state !is State.Failed

    private fun stateFor(details: Details): State {
        if (!details.protocolReady || !details.displayConfigured || !details.decoderReady) {
            return State.Negotiating(details)
        }
        if (!details.firstFrameRendered) {
            return State.WaitingForFirstFrame(details)
        }
        return State.Streaming(details)
    }

    private fun publish(next: State) {
        if (state == next) return
        state = next
        onStateChanged?.invoke(next)
    }
}
