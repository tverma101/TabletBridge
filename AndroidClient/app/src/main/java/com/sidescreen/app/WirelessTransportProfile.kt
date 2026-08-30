package com.sidescreen.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import java.net.Socket

/**
 * The Android half of the bounded wireless session profile.
 *
 * Video remains on the existing authenticated TCP protocol. The profile
 * keeps the socket readable under Wi-Fi bursts, binds both video and control
 * traffic to the same Wi-Fi route, and deliberately does not enable keepalive
 * or background reconnect work that would cost battery while idle.
 */
object WirelessTransportProfile {
    const val TARGET_FPS = 60
    const val VIDEO_SOCKET_RECEIVE_BUFFER_BYTES = 1024 * 1024
    const val VIDEO_STREAM_BUFFER_BYTES = 256 * 1024

    data class WifiRoute(
        val network: Network,
        val downstreamKbps: Int,
        val upstreamKbps: Int,
        val validated: Boolean,
        val score: Int,
    )

    /**
     * Prefer validated/unmetered Wi-Fi, but include local-only Wi-Fi as well.
     * Requiring NET_CAPABILITY_INTERNET here breaks direct/hotspot-style LAN
     * sharing even though the Mac is reachable on the local route.
     */
    @Suppress("DEPRECATION")
    fun findWifiRoute(context: Context): WifiRoute? {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        return connectivity.allNetworks.mapNotNull { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return@mapNotNull null

            val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            val hasInternet = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            val unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            val score =
                (if (validated) 4 else 0) +
                    (if (hasInternet) 2 else 0) +
                    (if (unmetered) 1 else 0)
            WifiRoute(
                network = network,
                downstreamKbps = caps.linkDownstreamBandwidthKbps,
                upstreamKbps = caps.linkUpstreamBandwidthKbps,
                validated = validated,
                score = score,
            )
        }.maxWithOrNull(compareBy<WifiRoute> { it.score }.thenBy { it.downstreamKbps })
    }

    /** Set only the video-side receive tuning; USB stays on its old path. */
    fun tuneVideoSocket(socket: Socket) {
        socket.tcpNoDelay = true
        // SO_RCVBUF is an optimization, not a connection prerequisite. Some
        // vendor stacks clamp or reject a requested size; keep their default
        // auto-tuning instead of failing the wireless handshake.
        runCatching {
            socket.receiveBufferSize = VIDEO_SOCKET_RECEIVE_BUFFER_BYTES
        }
    }

    /** Bind before connect so VPN/default-route selection cannot steal LAN traffic. */
    fun bindSocket(socket: Socket, route: WifiRoute): Boolean =
        runCatching {
            route.network.bindSocket(socket)
        }.isSuccess
}
