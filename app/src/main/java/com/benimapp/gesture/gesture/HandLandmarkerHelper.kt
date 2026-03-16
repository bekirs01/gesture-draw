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
    val indexTipX: Float,
    val indexTipY: Float,
    val isPinching: Boolean,
    val isErasing: Boolean,
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
    private var wasPinching = false
    private var wasErasing = false

    companion object {
        // İşaret + başparmak = yazma
        private const val PINCH_START_THRESHOLD = 0.07f
        private const val PINCH_RELEASE_THRESHOLD = 0.10f
        // İşaret + orta parmak = silme
        private const val ERASE_START_THRESHOLD = 0.08f
        private const val ERASE_RELEASE_THRESHOLD = 0.12f

        // Landmark indeksleri
        private const val THUMB_TIP = 4
        private const val INDEX_TIP = 8
        private const val MIDDLE_TIP = 12
        private const val RING_TIP = 16
        private const val PINKY_TIP = 20
        private const val INDEX_MCP = 5
        private const val MIDDLE_MCP = 9
        private const val RING_MCP = 13
        private const val PINKY_MCP = 17
        private const val WRIST = 0
    }

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
            resultListener(null)
            return
        }

        val landmarks = result.landmarks()[0]
        if (landmarks.size < 21) {
            resultListener(null)
            return
        }

        val thumbTip = landmarks[THUMB_TIP]
        val indexTip = landmarks[INDEX_TIP]
        val middleTip = landmarks[MIDDLE_TIP]

        // İşaret + başparmak = yazma
        val pinchDist = hypot(
            (thumbTip.x() - indexTip.x()).toDouble(),
            (thumbTip.y() - indexTip.y()).toDouble()
        ).toFloat()
        val isPinching = if (wasPinching) {
            pinchDist < PINCH_RELEASE_THRESHOLD
        } else {
            pinchDist < PINCH_START_THRESHOLD
        }
        wasPinching = isPinching

        // İşaret + orta parmak = silme (ikisini birleştirince sil)
        val indexMiddleDist = hypot(
            (indexTip.x() - middleTip.x()).toDouble(),
            (indexTip.y() - middleTip.y()).toDouble()
        ).toFloat()
        val isErasing = if (wasErasing) {
            indexMiddleDist < ERASE_RELEASE_THRESHOLD
        } else {
            indexMiddleDist < ERASE_START_THRESHOLD
        }
        wasErasing = isErasing

        resultListener(
            HandState(
                indexTipX = indexTip.x(),
                indexTipY = indexTip.y(),
                isPinching = isPinching,
                isErasing = isErasing,
                pinchDistance = pinchDist
            )
        )
    }

    private var reusableMatrix = Matrix()

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
