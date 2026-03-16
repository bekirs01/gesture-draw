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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.benimapp.gesture.data.PointData
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
    var statusText by remember { mutableStateOf("El bekleniyor...") }
    val currentDrawingPoints = remember { mutableStateListOf<PointData>() }

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
                                statusText = "El algılanmıyor"
                                if (currentDrawingPoints.isNotEmpty()) {
                                    syncRepository.sendDrawEvent(0f, 0f, isDrawing = false)
                                    currentDrawingPoints.clear()
                                }
                            } else if (state.isErasing) {
                                statusText = "İşaret+Orta - Siliniyor"
                                syncRepository.sendEraseEvent()
                                currentDrawingPoints.clear()
                            } else if (state.isPinching) {
                                statusText = "Çizim (başparmak+işaret)"
                                syncRepository.sendDrawEvent(state.indexTipX, state.indexTipY, isDrawing = true)
                                currentDrawingPoints.add(PointData(state.indexTipX, state.indexTipY))
                            } else {
                                statusText = "Başparmak+İşaret = Çiz | İşaret+Orta = Sil"
                                if (currentDrawingPoints.isNotEmpty()) {
                                    syncRepository.sendDrawEvent(state.indexTipX, state.indexTipY, isDrawing = false)
                                    currentDrawingPoints.clear()
                                }
                            }
                        },
                        errorListener = { e ->
                            Log.e("CameraScreen", "HandLandmarker hatası", e)
                            statusText = "Hata: ${e.message}"
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

        // Çizim noktalarını kamera önizlemesi üzerinde göster
        Canvas(modifier = Modifier.fillMaxSize()) {
            val points = currentDrawingPoints.toList()
            if (points.size >= 2) {
                for (i in 1 until points.size) {
                    drawLine(
                        color = Color(0xFF00FF9F),
                        start = Offset(points[i - 1].x * size.width, points[i - 1].y * size.height),
                        end = Offset(points[i].x * size.width, points[i].y * size.height),
                        strokeWidth = 6f,
                        cap = StrokeCap.Round
                    )
                }
            }

            // Parmak pozisyonu göstergesi
            currentHandState?.let { state ->
                val cx = state.indexTipX * size.width
                val cy = state.indexTipY * size.height
                val indicatorColor = if (state.isPinching) Color(0xFF00FF9F) else Color(0x88FFFFFF)
                drawCircle(
                    color = indicatorColor,
                    radius = if (state.isPinching) 16f else 10f,
                    center = Offset(cx, cy),
                    style = Stroke(width = 3f)
                )
            }
        }

        // Üst bilgi paneli
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
                    currentHandState != null -> Color(0xFFFFAA00)
                    else -> Color.Gray
                }
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(dotColor)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = statusText,
                    color = Color.White,
                    fontSize = 11.sp
                )
            }
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
