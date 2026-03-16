package com.benimapp.gesture.gesture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import kotlin.math.hypot

data class HandState(
    val cursorX: Float,
    val cursorY: Float,
    val isPinching: Boolean,
    val isErasing: Boolean,
    val eraserX: Float,
    val eraserY: Float,
    val handDetected: Boolean,
    val handSize: Float,
    val pinchDistance: Float
)

class HandLandmarkerHelper(
    private val context: Context,
    private val minDetectionConfidence: Float = 0.3f,
    private val minPresenceConfidence: Float = 0.3f,
    private val minTrackingConfidence: Float = 0.3f,
    private val resultListener: (HandState?) -> Unit,
    private val errorListener: (RuntimeException) -> Unit = {}
) {
    private var handLandmarker: HandLandmarker? = null

    companion object {
        private const val WRIST = 0
        private const val THUMB_TIP = 4
        private const val THUMB_IP = 3
        private const val INDEX_MCP = 5
        private const val INDEX_PIP = 6
        private const val INDEX_TIP = 8
        private const val MIDDLE_MCP = 9
        private const val MIDDLE_PIP = 10
        private const val MIDDLE_TIP = 12
        private const val RING_MCP = 13
        private const val RING_PIP = 14
        private const val RING_TIP = 16
        private const val PINKY_MCP = 17
        private const val PINKY_PIP = 18
        private const val PINKY_TIP = 20

        private const val CURSOR_SMOOTH = 0.45f
        private const val ERASE_SMOOTH = 0.5f
        private const val MIN_STROKE_DIST = 0.002f
        private const val GESTURE_LOCK_FRAMES = 3
        private const val PINCH_RELEASE_FRAMES = 4
    }

    private var wasPinching = false
    private var wasErasing = false
    private var smoothCursorX = 0.5f
    private var smoothCursorY = 0.5f
    private var smoothEraserX = 0.5f
    private var smoothEraserY = 0.5f
    private var pinchReleaseCounter = 0
    private var twoFingerHeldFrames = 0
    private var framesSinceDraw = Int.MAX_VALUE
    private var framesSinceErase = Int.MAX_VALUE

    init {
        setupHandLandmarker()
    }

    private fun buildOptions(delegate: Delegate) = HandLandmarker.HandLandmarkerOptions.builder()
        .setBaseOptions(
            BaseOptions.builder()
                .setModelAssetPath("hand_landmarker.task")
                .setDelegate(delegate)
                .build()
        )
        .setMinHandDetectionConfidence(minDetectionConfidence)
        .setMinHandPresenceConfidence(minPresenceConfidence)
        .setMinTrackingConfidence(minTrackingConfidence)
        .setNumHands(1)
        .setRunningMode(RunningMode.LIVE_STREAM)
        .setResultListener { result, _ -> processResult(result) }
        .setErrorListener { error -> errorListener(RuntimeException("HandLandmarker error", error)) }
        .build()

    private fun setupHandLandmarker() {
        handLandmarker = try {
            HandLandmarker.createFromOptions(context, buildOptions(Delegate.GPU))
        } catch (_: Exception) {
            HandLandmarker.createFromOptions(context, buildOptions(Delegate.CPU))
        }
    }

    private fun processResult(result: HandLandmarkerResult) {
        if (result.landmarks().isEmpty()) {
            resetState()
            resultListener(null)
            return
        }

        val lm = result.landmarks()[0]
        if (lm.size < 21) {
            resetState()
            resultListener(null)
            return
        }

        val handSize = hypot(
            (lm[WRIST].x() - lm[MIDDLE_MCP].x()).toDouble(),
            (lm[WRIST].y() - lm[MIDDLE_MCP].y()).toDouble()
        ).toFloat()

        val pinchStartThreshold = (handSize * 0.28f).coerceIn(0.025f, 0.1f)
        val pinchReleaseThreshold = (handSize * 0.4f).coerceIn(0.04f, 0.14f)

        val thumbTip = lm[THUMB_TIP]
        val indexTip = lm[INDEX_TIP]
        val middleTip = lm[MIDDLE_TIP]

        val pinchDist = hypot(
            (thumbTip.x() - indexTip.x()).toDouble(),
            (thumbTip.y() - indexTip.y()).toDouble()
        ).toFloat()

        val indexExtended = isFingerExtended(lm, INDEX_MCP, INDEX_PIP, INDEX_TIP)
        val middleExtended = isFingerExtended(lm, MIDDLE_MCP, MIDDLE_PIP, MIDDLE_TIP)
        val ringCurled = !isFingerExtended(lm, RING_MCP, RING_PIP, RING_TIP)
        val pinkyCurled = !isFingerExtended(lm, PINKY_MCP, PINKY_PIP, PINKY_TIP)

        val twoFingerEraseDetected = indexExtended && middleExtended && ringCurled && pinkyCurled

        if (twoFingerEraseDetected) {
            twoFingerHeldFrames++
        } else {
            twoFingerHeldFrames = 0
        }

        val eraseActive = twoFingerHeldFrames >= 2 && framesSinceDraw >= GESTURE_LOCK_FRAMES

        val rawPinch = pinchDist < if (wasPinching) pinchReleaseThreshold else pinchStartThreshold

        val pinchActive: Boolean
        if (eraseActive) {
            pinchActive = false
            pinchReleaseCounter = 0
        } else if (rawPinch && framesSinceErase >= GESTURE_LOCK_FRAMES) {
            pinchActive = true
            pinchReleaseCounter = 0
        } else if (wasPinching && !rawPinch) {
            pinchReleaseCounter++
            pinchActive = pinchReleaseCounter < PINCH_RELEASE_FRAMES
        } else {
            pinchActive = false
            pinchReleaseCounter = 0
        }

        if (pinchActive) {
            framesSinceDraw = 0
            framesSinceErase++
        } else if (eraseActive) {
            framesSinceErase = 0
            framesSinceDraw++
        } else {
            framesSinceDraw++
            framesSinceErase++
        }

        wasPinching = pinchActive
        wasErasing = eraseActive

        val rawCursorX: Float
        val rawCursorY: Float
        if (pinchActive) {
            rawCursorX = (indexTip.x() + thumbTip.x()) / 2f
            rawCursorY = (indexTip.y() + thumbTip.y()) / 2f
        } else {
            rawCursorX = indexTip.x()
            rawCursorY = indexTip.y()
        }
        smoothCursorX = lerp(smoothCursorX, rawCursorX, 1f - CURSOR_SMOOTH)
        smoothCursorY = lerp(smoothCursorY, rawCursorY, 1f - CURSOR_SMOOTH)

        val rawEraserX = (indexTip.x() + middleTip.x()) / 2f
        val rawEraserY = (indexTip.y() + middleTip.y()) / 2f
        smoothEraserX = lerp(smoothEraserX, rawEraserX, 1f - ERASE_SMOOTH)
        smoothEraserY = lerp(smoothEraserY, rawEraserY, 1f - ERASE_SMOOTH)

        resultListener(
            HandState(
                cursorX = smoothCursorX,
                cursorY = smoothCursorY,
                isPinching = pinchActive,
                isErasing = eraseActive,
                eraserX = smoothEraserX,
                eraserY = smoothEraserY,
                handDetected = true,
                handSize = handSize,
                pinchDistance = pinchDist
            )
        )
    }

    private fun isFingerExtended(
        lm: List<com.google.mediapipe.tasks.components.containers.NormalizedLandmark>,
        mcp: Int, pip: Int, tip: Int
    ): Boolean {
        val mcpToTip = hypot(
            (lm[tip].x() - lm[mcp].x()).toDouble(),
            (lm[tip].y() - lm[mcp].y()).toDouble()
        )
        val mcpToPip = hypot(
            (lm[pip].x() - lm[mcp].x()).toDouble(),
            (lm[pip].y() - lm[mcp].y()).toDouble()
        )
        return mcpToTip > mcpToPip * 1.2
    }

    private fun lerp(a: Float, b: Float, t: Float): Float = a + (b - a) * t

    private fun resetState() {
        wasPinching = false
        wasErasing = false
        pinchReleaseCounter = 0
        twoFingerHeldFrames = 0
    }

    private val reusableMatrix = Matrix()

    fun recognizeAsync(bitmap: Bitmap, rotationDegrees: Int = 0) {
        reusableMatrix.reset()
        reusableMatrix.postRotate(rotationDegrees.toFloat())
        reusableMatrix.postScale(-1f, 1f, bitmap.width / 2f, bitmap.height / 2f)

        val transformed = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, reusableMatrix, false
        )
        val mpImage = BitmapImageBuilder(transformed).build()
        handLandmarker?.detectAsync(mpImage, SystemClock.uptimeMillis())
        if (transformed != bitmap) transformed.recycle()
    }

    fun close() {
        handLandmarker?.close()
        handLandmarker = null
    }
}
