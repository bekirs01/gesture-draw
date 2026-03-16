package com.benimapp.gesture.gesture

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult

/**
 * MediaPipe Gesture Recognizer yardımcı sınıfı.
 * El hareketlerini algılar ve sonuçları callback ile iletir.
 */
class GestureRecognizerHelper(
    private val context: Context,
    private val minHandDetectionConfidence: Float = 0.5f,
    private val minHandPresenceConfidence: Float = 0.5f,
    private val minTrackingConfidence: Float = 0.5f,
    private val numHands: Int = 2,
    private val resultListener: (GestureRecognizerResult?, MPImage) -> Unit,
    private val errorListener: (RuntimeException) -> Unit = {}
) {
    private var gestureRecognizer: GestureRecognizer? = null

    init {
        setupGestureRecognizer()
    }

    private fun setupGestureRecognizer() {
        val baseOptionsBuilder = BaseOptions.builder()
            .setModelAssetPath("gesture_recognizer.task")
            .setDelegate(Delegate.CPU)

        val options = com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer.GestureRecognizerOptions.builder()
            .setBaseOptions(baseOptionsBuilder.build())
            .setMinHandDetectionConfidence(minHandDetectionConfidence)
            .setMinHandPresenceConfidence(minHandPresenceConfidence)
            .setMinTrackingConfidence(minTrackingConfidence)
            .setNumHands(numHands)
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setResultListener { result, image ->
                resultListener(result, image)
            }
            .setErrorListener { error ->
                errorListener(RuntimeException("Gesture recognizer error", error))
            }
            .build()

        gestureRecognizer = GestureRecognizer.createFromOptions(context, options)
    }

    /**
     * Kamera frame'ini işler. LIVE_STREAM modunda asenkron çalışır.
     * @param rotationDegrees Kamera rotasyonu (ImageProxy.imageInfo.rotationDegrees)
     */
    fun recognizeAsync(bitmap: Bitmap, rotationDegrees: Int = 0) {
        val matrix = Matrix().apply {
            postRotate(rotationDegrees.toFloat())
            postScale(-1f, 1f, bitmap.width / 2f, bitmap.height / 2f) // Ön kamera ayna
        }
        val transformedBitmap = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
        )
        val mpImage = BitmapImageBuilder(transformedBitmap).build()
        val frameTime = SystemClock.uptimeMillis()
        gestureRecognizer?.recognizeAsync(mpImage, frameTime)
    }

    fun close() {
        gestureRecognizer?.close()
        gestureRecognizer = null
    }
}
