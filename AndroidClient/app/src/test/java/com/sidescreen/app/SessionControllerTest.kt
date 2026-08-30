package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionControllerTest {
    @Test
    fun streamingRequiresARealRenderedFrame() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.USB)

        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)

        assertTrue(controller.state is SessionController.State.WaitingForFirstFrame)
        assertFalse(controller.isStreaming(generation))

        controller.frameDecoded(generation)
        assertTrue(controller.state is SessionController.State.WaitingForFirstFrame)
        controller.surfaceRendered(generation)

        assertTrue(controller.state is SessionController.State.Streaming)
        assertTrue(controller.shouldForwardTouch())
        assertTrue(controller.ownsBrightness(generation))
    }

    @Test
    fun staleGenerationCannotReenterOrOwnBrightness() {
        val controller = SessionController()
        val oldGeneration = controller.begin(ConnectionMode.USB)
        controller.disconnect("test")
        val newGeneration = controller.begin(ConnectionMode.WIRELESS)

        assertFalse(controller.isCurrent(oldGeneration))
        assertFalse(controller.protocolNegotiated(oldGeneration))
        assertEquals(newGeneration, controller.stateGeneration())
    }

    @Test
    fun controlFailureDegradesStreamingWithoutDisconnectingIt() {
        val controller = SessionController()
        val generation = controller.begin(ConnectionMode.USB)
        controller.transportConnected(generation)
        controller.protocolNegotiated(generation)
        controller.displayConfigured(generation)
        controller.decoderStarted(generation)
        controller.surfaceRendered(generation)
        controller.controlHealthy(generation, false)

        val state = controller.state as SessionController.State.Streaming
        assertEquals(SessionController.ControlHealth.DEGRADED, state.details.control)
        assertTrue(controller.isStreaming(generation))
    }

    private fun SessionController.stateGeneration(): Long? = when (val state = state) {
        is SessionController.State.Connecting -> state.generation
        is SessionController.State.Negotiating -> state.details.generation
        is SessionController.State.WaitingForFirstFrame -> state.details.generation
        is SessionController.State.Streaming -> state.details.generation
        else -> null
    }
}
