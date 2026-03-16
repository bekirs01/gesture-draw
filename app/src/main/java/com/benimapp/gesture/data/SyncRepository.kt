package com.benimapp.gesture.data

import android.util.Log
import com.google.gson.Gson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.net.URLDecoder
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

class SyncRepository(private val projectLink: String) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val api = SupabaseClient.api
    private val gson = Gson()

    private var currentStrokePoints = mutableListOf<PointData>()
    private var isDrawing = false
    private var lastEraseTime = 0L
    private val eraseDebounceMs = 1500L
    private var lastBroadcastTime = 0L
    private val broadcastDebounceMs = 50L

    val shareToken: String? = extractShareToken(projectLink)
    private val pageNum = 1

    private var realtimeSocket: WebSocket? = null

    init {
        if (shareToken != null) {
            connectRealtime()
        }
    }

    private fun extractShareToken(link: String): String? {
        return try {
            val idPattern = Pattern.compile("[?&]id=([^&]+)")
            val idMatcher = idPattern.matcher(link)
            if (idMatcher.find()) {
                return URLDecoder.decode(idMatcher.group(1), "UTF-8").trim()
            }
            val segments = link.split("/").filter { it.isNotBlank() }
            segments.lastOrNull()?.takeIf { it.length > 3 && !it.startsWith("http") }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Supabase Realtime WebSocket bağlantısı.
     * Broadcast ile diğer istemcilere anlık stroke verisi gönderir.
     */
    private fun connectRealtime() {
        val wsUrl = SupabaseConfig.SUPABASE_URL
            .replace("https://", "wss://")
            .replace("http://", "ws://") +
                "/realtime/v1/websocket?apikey=${SupabaseConfig.SUPABASE_ANON_KEY}&vsn=1.0.0"

        val client = OkHttpClient.Builder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

        val request = Request.Builder().url(wsUrl).build()

        realtimeSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "Realtime bağlantı açıldı")
                val joinMsg = """{"topic":"realtime:pdf_page_strokes:$shareToken","event":"phx_join","payload":{"config":{"broadcast":{"self":false}}},"ref":"1"}"""
                webSocket.send(joinMsg)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                Log.d(TAG, "Realtime mesaj: ${text.take(100)}")
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "Realtime bağlantı hatası", t)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Realtime bağlantı kapandı: $reason")
            }
        })

        // Heartbeat gönder
        scope.launch {
            while (true) {
                kotlinx.coroutines.delay(30_000)
                try {
                    realtimeSocket?.send("""{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"hb"}""")
                } catch (_: Exception) { break }
            }
        }
    }

    private fun broadcastStrokeProgress(points: List<PointData>) {
        val now = System.currentTimeMillis()
        if (now - lastBroadcastTime < broadcastDebounceMs) return
        lastBroadcastTime = now

        val payload = mapOf(
            "type" to "broadcast",
            "event" to "stroke_progress",
            "payload" to mapOf(
                "pageNum" to pageNum,
                "stroke" to mapOf(
                    "points" to points.map { mapOf("x" to it.x, "y" to it.y) },
                    "color" to "#00ff9f",
                    "lineWidth" to 4
                )
            )
        )
        val msg = """{"topic":"realtime:pdf_page_strokes:$shareToken","event":"broadcast","payload":${gson.toJson(payload)},"ref":"bp"}"""

        try {
            realtimeSocket?.send(msg)
        } catch (e: Exception) {
            Log.w(TAG, "Broadcast gönderilemedi", e)
        }
    }

    private fun broadcastStrokeComplete(strokes: List<StrokeData>) {
        val payload = mapOf(
            "type" to "broadcast",
            "event" to "stroke",
            "payload" to mapOf(
                "pageNum" to pageNum,
                "strokes" to strokes.map { s ->
                    mapOf(
                        "points" to s.points.map { mapOf("x" to it.x, "y" to it.y) },
                        "color" to s.color,
                        "lineWidth" to s.lineWidth
                    )
                }
            )
        )
        val msg = """{"topic":"realtime:pdf_page_strokes:$shareToken","event":"broadcast","payload":${gson.toJson(payload)},"ref":"bs"}"""

        try {
            realtimeSocket?.send(msg)
        } catch (e: Exception) {
            Log.w(TAG, "Broadcast gönderilemedi", e)
        }
    }

    fun sendDrawEvent(x: Float, y: Float, isDrawing: Boolean) {
        if (shareToken == null) return

        when {
            isDrawing -> {
                this.isDrawing = true
                val last = currentStrokePoints.lastOrNull()
                if (last == null || kotlin.math.hypot(x - last.x, y - last.y) > 0.01f) {
                    currentStrokePoints.add(PointData(x, y))
                    broadcastStrokeProgress(currentStrokePoints.toList())
                }
            }
            this.isDrawing -> {
                this.isDrawing = false
                if (currentStrokePoints.size >= 2) {
                    saveStroke(currentStrokePoints.toList())
                }
                currentStrokePoints.clear()
            }
        }
    }

    fun sendEraseEvent() {
        if (shareToken == null) return
        val now = System.currentTimeMillis()
        if (now - lastEraseTime < eraseDebounceMs) return
        lastEraseTime = now

        scope.launch {
            try {
                api.deletePageStrokes(shareToken, pageNum)
                currentStrokePoints.clear()
                broadcastStrokeComplete(emptyList())
            } catch (e: Exception) {
                savePageStrokes(emptyList())
            }
        }
    }

    private fun saveStroke(points: List<PointData>) {
        val stroke = StrokeData(
            points = points,
            color = "#00ff9f",
            lineWidth = 4
        )
        scope.launch {
            try {
                val existing = fetchPageStrokes()
                val newStrokes = existing + stroke
                savePageStrokes(newStrokes)
                broadcastStrokeComplete(newStrokes)
            } catch (e: Exception) {
                savePageStrokes(listOf(stroke))
                broadcastStrokeComplete(listOf(stroke))
            }
        }
    }

    private suspend fun fetchPageStrokes(): List<StrokeData> {
        val response = api.getPageStrokes(
            shareTokenFilter = "eq.$shareToken",
            pageNumFilter = "eq.$pageNum"
        )
        if (!response.isSuccessful) return emptyList()
        return response.body()?.firstOrNull()?.strokes ?: emptyList()
    }

    private fun savePageStrokes(strokes: List<StrokeData>) {
        val validStrokes = strokes.filter { it.points.size >= 2 }

        scope.launch {
            try {
                api.upsertPageStrokes(
                    PdfPageStrokesUpsert(
                        share_token = shareToken!!,
                        page_num = pageNum,
                        strokes = validStrokes,
                        updated_at = java.text.SimpleDateFormat(
                            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                            java.util.Locale.US
                        ).apply {
                            timeZone = java.util.TimeZone.getTimeZone("UTC")
                        }.format(java.util.Date())
                    )
                )
            } catch (e: Exception) {
                Log.e(TAG, "Kaydetme hatası", e)
            }
        }
    }

    fun getProjectIdFromLink(): String? = shareToken

    fun destroy() {
        realtimeSocket?.close(1000, "Uygulama kapandı")
        realtimeSocket = null
    }

    companion object {
        private const val TAG = "SyncRepository"
    }
}
