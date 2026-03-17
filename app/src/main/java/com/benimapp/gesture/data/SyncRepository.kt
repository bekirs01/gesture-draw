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
import kotlin.math.hypot

class SyncRepository(private val projectLink: String) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val api = SupabaseClient.api
    private val gson = Gson()

    private var currentStrokePoints = mutableListOf<PointData>()
    private var isDrawing = false
    private var lastBroadcastTime = 0L
    private var lastPointerBroadcastTime = 0L
    private val broadcastDebounceMs = 50L
    private val pointerBroadcastDebounceMs = 8L

    val shareToken: String? = extractShareToken(projectLink)
    private val pageNum = 1

    private var realtimeSocket: WebSocket? = null
    private var cachedStrokes = mutableListOf<StrokeData>()

    companion object {
        private const val TAG = "SyncRepository"
        private const val ERASE_RADIUS = 0.09f
        private const val ERASE_RADIUS_SQ = ERASE_RADIUS * ERASE_RADIUS
        private const val MIN_STROKE_DIST = 0.002f
        private const val DP_EPSILON = 0.002f
    }

    init {
        if (shareToken != null) {
            connectRealtime()
            loadInitialStrokes()
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
        } catch (_: Exception) {
            null
        }
    }

    private fun loadInitialStrokes() {
        scope.launch {
            try {
                val existing = fetchPageStrokes()
                synchronized(cachedStrokes) {
                    cachedStrokes.clear()
                    cachedStrokes.addAll(existing)
                }
            } catch (e: Exception) {
                Log.w(TAG, "İlk stroke yükleme hatası", e)
            }
        }
    }

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
        try { realtimeSocket?.send(msg) } catch (e: Exception) { Log.w(TAG, "Broadcast hatası", e) }
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
        try { realtimeSocket?.send(msg) } catch (e: Exception) { Log.w(TAG, "Broadcast hatası", e) }
    }

    fun mirrorX(camX: Float): Float = 1f - camX

    fun sendPointerPosition(x: Float, y: Float) {
        if (shareToken == null) return
        val now = System.currentTimeMillis()
        if (now - lastPointerBroadcastTime < pointerBroadcastDebounceMs) return
        lastPointerBroadcastTime = now
        val docX = mirrorX(x)
        val payload = mapOf(
            "type" to "broadcast",
            "event" to "pointer_position",
            "payload" to mapOf("pageNum" to pageNum, "x" to docX, "y" to y)
        )
        val msg = """{"topic":"realtime:pdf_page_strokes:$shareToken","event":"broadcast","payload":${gson.toJson(payload)},"ref":"ptr"}"""
        try { realtimeSocket?.send(msg) } catch (e: Exception) { Log.w(TAG, "Pointer broadcast hatası", e) }
    }

    fun sendPointerHidden() {
        if (shareToken == null) return
        val payload = mapOf(
            "type" to "broadcast",
            "event" to "pointer_hidden",
            "payload" to mapOf("pageNum" to pageNum)
        )
        val msg = """{"topic":"realtime:pdf_page_strokes:$shareToken","event":"broadcast","payload":${gson.toJson(payload)},"ref":"ptr"}"""
        try { realtimeSocket?.send(msg) } catch (e: Exception) { Log.w(TAG, "Pointer hidden hatası", e) }
    }

    fun sendDrawEvent(camX: Float, camY: Float, isDrawing: Boolean, discardStroke: Boolean = false) {
        if (shareToken == null) return

        val docX = mirrorX(camX)
        val docY = camY

        when {
            isDrawing -> {
                this.isDrawing = true
                val last = currentStrokePoints.lastOrNull()
                val dist = if (last != null) hypot((docX - last.x).toDouble(), (docY - last.y).toDouble()).toFloat() else Float.MAX_VALUE
                if (dist > MIN_STROKE_DIST) {
                    currentStrokePoints.add(PointData(docX, docY))
                    broadcastStrokeProgress(currentStrokePoints.toList())
                }
            }
            this.isDrawing -> {
                this.isDrawing = false
                if (discardStroke) {
                    currentStrokePoints.clear()
                    return
                }
                if (currentStrokePoints.size >= 2) {
                    val simplified = simplifyPoints(currentStrokePoints, DP_EPSILON)
                    val stroke = StrokeData(points = simplified, color = "#00ff9f", lineWidth = 4)
                    synchronized(cachedStrokes) {
                        cachedStrokes.add(stroke)
                    }
                    currentStrokePoints.clear()
                    saveStroke(simplified)
                } else {
                    currentStrokePoints.clear()
                }
            }
        }
    }

    fun sendEraseAtPosition(camX: Float, camY: Float) {
        if (shareToken == null) return

        val docX = mirrorX(camX)
        val docY = camY

        scope.launch {
            val modified: List<StrokeData>
            synchronized(cachedStrokes) {
                modified = eraseLayerAtPosition(cachedStrokes, docX, docY)
                cachedStrokes.clear()
                cachedStrokes.addAll(modified)
            }
            savePageStrokes(modified)
            broadcastStrokeComplete(modified)
        }
    }

    private fun eraseLayerAtPosition(
        strokes: List<StrokeData>,
        ex: Float, ey: Float
    ): List<StrokeData> {
        val result = mutableListOf<StrokeData>()
        for (stroke in strokes) {
            val segments = splitStrokeByEraser(stroke.points, ex, ey)
            for (seg in segments) {
                if (seg.size >= 2) {
                    result.add(stroke.copy(points = seg))
                }
            }
        }
        return result
    }

    private fun splitStrokeByEraser(
        points: List<PointData>,
        ex: Float, ey: Float
    ): List<List<PointData>> {
        val segments = mutableListOf<List<PointData>>()
        var currentSeg = mutableListOf<PointData>()

        for (p in points) {
            val dx = p.x - ex
            val dy = p.y - ey
            val distSq = dx * dx + dy * dy
            if (distSq < ERASE_RADIUS_SQ) {
                if (currentSeg.size >= 2) segments.add(currentSeg.toList())
                currentSeg = mutableListOf()
            } else {
                currentSeg.add(p)
            }
        }
        if (currentSeg.size >= 2) segments.add(currentSeg.toList())
        return segments
    }

    private fun saveStroke(points: List<PointData>) {
        val stroke = StrokeData(points = points, color = "#00ff9f", lineWidth = 4)
        scope.launch {
            try {
                val existing = fetchPageStrokes()
                val newStrokes = existing + stroke
                synchronized(cachedStrokes) {
                    cachedStrokes.clear()
                    cachedStrokes.addAll(newStrokes)
                }
                savePageStrokes(newStrokes)
                broadcastStrokeComplete(newStrokes)
            } catch (e: Exception) {
                synchronized(cachedStrokes) { cachedStrokes.add(stroke) }
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

    fun getCachedStrokes(): List<StrokeData> {
        synchronized(cachedStrokes) {
            return cachedStrokes.toList()
        }
    }

    fun getProjectIdFromLink(): String? = shareToken

    fun destroy() {
        realtimeSocket?.close(1000, "Uygulama kapandı")
        realtimeSocket = null
    }
}

fun simplifyPoints(points: List<PointData>, epsilon: Float): List<PointData> {
    if (points.size <= 2) return points

    var maxDist = 0f
    var maxIdx = 0

    val start = points.first()
    val end = points.last()

    for (i in 1 until points.size - 1) {
        val d = perpendicularDistance(points[i], start, end)
        if (d > maxDist) {
            maxDist = d
            maxIdx = i
        }
    }

    return if (maxDist > epsilon) {
        val left = simplifyPoints(points.subList(0, maxIdx + 1), epsilon)
        val right = simplifyPoints(points.subList(maxIdx, points.size), epsilon)
        left.dropLast(1) + right
    } else {
        listOf(start, end)
    }
}

private fun perpendicularDistance(point: PointData, lineStart: PointData, lineEnd: PointData): Float {
    val dx = lineEnd.x - lineStart.x
    val dy = lineEnd.y - lineStart.y
    val lenSq = dx * dx + dy * dy
    if (lenSq == 0f) return hypot((point.x - lineStart.x).toDouble(), (point.y - lineStart.y).toDouble()).toFloat()

    val t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lenSq
    val tc = t.coerceIn(0f, 1f)
    val projX = lineStart.x + tc * dx
    val projY = lineStart.y + tc * dy
    return hypot((point.x - projX).toDouble(), (point.y - projY).toDouble()).toFloat()
}
