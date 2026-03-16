package com.benimapp.gesture.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.util.Log
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.benimapp.gesture.data.PointData
import com.benimapp.gesture.data.StrokeData
import com.benimapp.gesture.data.SyncRepository
import com.benimapp.gesture.gesture.HandLandmarkerHelper
import com.benimapp.gesture.gesture.HandState
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

@Composable
fun CameraScreen(
    projectLink: String,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        hasCameraPermission = isGranted
    }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    if (!hasCameraPermission) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Kamera izni gerekli", style = MaterialTheme.typography.titleLarge)
                Text(
                    "El hareketlerinizi algılamak için kamera erişimine ihtiyacımız var.",
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(top = 8.dp)
                )
                Button(
                    onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) },
                    modifier = Modifier.padding(top = 16.dp)
                ) {
                    Text("İzin Ver")
                }
            }
        }
        return
    }

    val syncRepository = remember(projectLink) { SyncRepository(projectLink) }
    var handHelper by remember { mutableStateOf<HandLandmarkerHelper?>(null) }
    var currentHandState by remember { mutableStateOf<HandState?>(null) }
    val currentDrawingPoints = remember { mutableStateListOf<PointData>() }
    var savedStrokes by remember { mutableStateOf<List<StrokeData>>(emptyList()) }

    LaunchedEffect(Unit) {
        while (true) {
            savedStrokes = syncRepository.getCachedStrokes()
            kotlinx.coroutines.delay(500)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            handHelper?.close()
            syncRepository.destroy()
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AndroidView(
            factory = { ctx ->
                val previewView = PreviewView(ctx).apply {
                    implementationMode = PreviewView.ImplementationMode.PERFORMANCE
                    scaleType = PreviewView.ScaleType.FILL_CENTER
                }
                val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                cameraProviderFuture.addListener({
                    val cameraProvider = cameraProviderFuture.get()
                    val preview = Preview.Builder()
                        .build()
                        .also {
                            it.setSurfaceProvider(previewView.getSurfaceProvider())
                        }

                    val executor = Executors.newSingleThreadExecutor()
                    val helper = HandLandmarkerHelper(
                        context = ctx,
                        resultListener = { state ->
                            currentHandState = state
                            if (state == null) {
                                syncRepository.sendPointerHidden()
                                if (currentDrawingPoints.isNotEmpty()) {
                                    syncRepository.sendDrawEvent(0f, 0f, isDrawing = false)
                                    currentDrawingPoints.clear()
                                }
                            } else if (state.isErasing) {
                                syncRepository.sendPointerHidden()
                                syncRepository.sendEraseAtPosition(state.eraserX, state.eraserY)
                                if (currentDrawingPoints.isNotEmpty()) {
                                    currentDrawingPoints.clear()
                                }
                                savedStrokes = syncRepository.getCachedStrokes()
                            } else if (state.isPinching) {
                                syncRepository.sendPointerHidden()
                                syncRepository.sendDrawEvent(state.cursorX, state.cursorY, isDrawing = true)
                                val docX = syncRepository.mirrorX(state.cursorX)
                                currentDrawingPoints.add(PointData(docX, state.cursorY))
                            } else if (state.handDetected) {
                                syncRepository.sendPointerPosition(state.cursorX, state.cursorY)
                                if (currentDrawingPoints.isNotEmpty()) {
                                    syncRepository.sendDrawEvent(state.cursorX, state.cursorY, isDrawing = false)
                                    currentDrawingPoints.clear()
                                    savedStrokes = syncRepository.getCachedStrokes()
                                }
                            } else {
                                syncRepository.sendPointerHidden()
                            }
                        },
                        errorListener = { e ->
                            Log.e("CameraScreen", "HandLandmarker hatası", e)
                        }
                    )
                    handHelper = helper

                    val frameCounter = AtomicInteger(0)
                    val imageAnalyzer = ImageAnalysis.Builder()
                        .setTargetResolution(Size(320, 240))
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                        .also {
                            it.setAnalyzer(executor) { imageProxy ->
                                if (frameCounter.incrementAndGet() % 3 == 0) {
                                    processFrame(imageProxy, helper)
                                } else {
                                    imageProxy.close()
                                }
                            }
                        }

                    try {
                        cameraProvider.unbindAll()
                        try {
                            cameraProvider.bindToLifecycle(
                                lifecycleOwner,
                                CameraSelector.DEFAULT_FRONT_CAMERA,
                                preview,
                                imageAnalyzer
                            )
                        } catch (e: Exception) {
                            Log.e("CameraScreen", "Ön kamera başarısız, arka deneniyor", e)
                            cameraProvider.bindToLifecycle(
                                lifecycleOwner,
                                CameraSelector.DEFAULT_BACK_CAMERA,
                                preview,
                                imageAnalyzer
                            )
                        }
                    } catch (e: Exception) {
                        Log.e("CameraScreen", "Kamera bağlama hatası", e)
                    }
                }, ContextCompat.getMainExecutor(ctx))
                previewView
            },
            modifier = Modifier.fillMaxSize()
        )

        Canvas(modifier = Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height

            for (stroke in savedStrokes) {
                val pts = stroke.points
                if (pts.size >= 2) {
                    val strokeColor = try {
                        Color(android.graphics.Color.parseColor(stroke.color))
                    } catch (_: Exception) {
                        Color(0xFF00FF9F)
                    }
                    for (i in 1 until pts.size) {
                        drawLine(
                            color = strokeColor,
                            start = Offset(pts[i - 1].x * w, pts[i - 1].y * h),
                            end = Offset(pts[i].x * w, pts[i].y * h),
                            strokeWidth = stroke.lineWidth.toFloat() * 1.5f,
                            cap = StrokeCap.Round
                        )
                    }
                }
            }

            val drawPts = currentDrawingPoints.toList()
            if (drawPts.size >= 2) {
                for (i in 1 until drawPts.size) {
                    drawLine(
                        color = Color(0xFF00FF9F),
                        start = Offset(drawPts[i - 1].x * w, drawPts[i - 1].y * h),
                        end = Offset(drawPts[i].x * w, drawPts[i].y * h),
                        strokeWidth = 6f,
                        cap = StrokeCap.Round
                    )
                }
            }

            currentHandState?.let { state ->
                if (state.isErasing) {
                    val ex = state.eraserX * w
                    val ey = state.eraserY * h
                    val eraserRadius = 0.09f * w
                    drawCircle(
                        color = Color(0xAAFF4444),
                        radius = eraserRadius,
                        center = Offset(ex, ey),
                        style = Stroke(
                            width = 3f,
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 8f))
                        )
                    )
                    drawCircle(
                        color = Color(0x33FF4444),
                        radius = eraserRadius,
                        center = Offset(ex, ey)
                    )
                } else {
                    val cx = state.cursorX * w
                    val cy = state.cursorY * h
                    if (state.isPinching) {
                        drawCircle(
                            color = Color(0xFF00FF9F),
                            radius = 16f,
                            center = Offset(cx, cy),
                            style = Stroke(width = 3f)
                        )
                        drawCircle(
                            color = Color(0x4400FF9F),
                            radius = 8f,
                            center = Offset(cx, cy)
                        )
                    } else if (state.handDetected) {
                        drawCircle(
                            color = Color(0x66FF4444),
                            radius = 16f,
                            center = Offset(cx, cy)
                        )
                        drawCircle(
                            color = Color(0xFFFF4444),
                            radius = 8f,
                            center = Offset(cx, cy)
                        )
                        drawCircle(
                            color = Color.White,
                            radius = 8f,
                            center = Offset(cx, cy),
                            style = Stroke(width = 1.5f)
                        )
                    }
                }
            }
        }

        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(16.dp)
                .background(
                    Color.Black.copy(alpha = 0.6f),
                    RoundedCornerShape(12.dp)
                )
                .padding(12.dp)
        ) {
            Button(
                onClick = onBack,
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.error
                )
            ) {
                Text("← Geri")
            }
            Text(
                text = "ID: ${syncRepository.getProjectIdFromLink() ?: "Geçersiz"}",
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp)
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(top = 4.dp)
            ) {
                val dotColor = when {
                    currentHandState?.isPinching == true -> Color(0xFF00FF9F)
                    currentHandState?.isErasing == true -> Color(0xFFFF4444)
                    currentHandState?.handDetected == true -> Color(0xFFFFAA00)
                    else -> Color.Gray
                }
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(dotColor)
                )
            }
            Text(
                text = "Çizgiler: ${savedStrokes.size}",
                color = Color.White.copy(alpha = 0.6f),
                fontSize = 10.sp,
                modifier = Modifier.padding(top = 2.dp)
            )
        }
    }
}

private fun processFrame(imageProxy: ImageProxy, helper: HandLandmarkerHelper) {
    try {
        val original = imageProxy.toBitmap()
        val scaled = if (original.width > 320) {
            val ratio = 320f / original.width
            val w = 320
            val h = (original.height * ratio).toInt()
            Bitmap.createScaledBitmap(original, w, h, false).also {
                original.recycle()
            }
        } else {
            original
        }
        helper.recognizeAsync(scaled, imageProxy.imageInfo.rotationDegrees)
        scaled.recycle()
    } catch (_: Exception) {
    } finally {
        imageProxy.close()
    }
}
