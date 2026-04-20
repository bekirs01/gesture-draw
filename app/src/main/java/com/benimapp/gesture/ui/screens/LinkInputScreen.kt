package com.benimapp.gesture.ui.screens

import android.app.Activity
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.Canvas
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import kotlin.math.sin
import kotlin.random.Random

private data class Snowflake(
    val x: Float,
    val y: Float,
    val speed: Float,
    val radius: Float,
    val phase: Float
) {
    fun step(width: Float, height: Float): Snowflake {
        val ny = y + speed
        val nx = x + sin((phase + ny) * 0.018f) * 2.2f
        return if (ny > height + 24f) {
            Snowflake(
                x = Random.nextFloat() * width,
                y = -Random.nextFloat() * 48f,
                speed = speed,
                radius = radius,
                phase = phase + Random.nextFloat() * 2f
            )
        } else {
            copy(x = nx.coerceIn(-8f, width + 8f), y = ny)
        }
    }
}

@Composable
private fun FastSnowfallBackground(modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier = modifier) {
        val density = LocalDensity.current
        val w = with(density) { maxWidth.toPx() }
        val h = with(density) { maxHeight.toPx() }
        if (w <= 0f || h <= 0f) return@BoxWithConstraints

        var flakes by remember(w, h) {
            mutableStateOf(
                List(150) {
                    Snowflake(
                        x = Random.nextFloat() * w,
                        y = Random.nextFloat() * h,
                        speed = Random.nextFloat() * 14f + 12f,
                        radius = Random.nextFloat() * 2.5f + 1f,
                        phase = Random.nextFloat() * 1200f
                    )
                }
            )
        }

        LaunchedEffect(w, h) {
            while (true) {
                withFrameNanos {
                    flakes = flakes.map { it.step(w, h) }
                }
            }
        }

        Canvas(Modifier.fillMaxSize()) {
            flakes.forEach { f ->
                drawCircle(
                    color = Color.White.copy(alpha = 0.62f),
                    radius = f.radius,
                    center = Offset(f.x, f.y)
                )
            }
        }
    }
}

@Composable
fun LinkInputScreen(
    onLinkSubmitted: (String) -> Unit
) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = false
        }
    }

    var link by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    fun validateAndSubmit() {
        val trimmed = link.trim()
        when {
            trimmed.isBlank() -> error = "Введите ссылку"
            !trimmed.startsWith("http://") && !trimmed.startsWith("https://") ->
                error = "Укажите корректный URL (с http:// или https://)"
            !trimmed.contains("id=") && !trimmed.contains("view") ->
                error = "В ссылке нужен идентификатор (?id=…) или параметр view"
            else -> onLinkSubmitted(trimmed)
        }
    }

    val deepBlue0 = Color(0xFF061A33)
    val deepBlue1 = Color(0xFF0F3566)
    val deepBlue2 = Color(0xFF174A8C)
    val accentBlue = Color(0xFF5EB0FF)
    val accentBlueDeep = Color(0xFF2B7BD4)
    val cardSurface = Color(0xD9163058)
    val subtleLine = Color.White.copy(alpha = 0.14f)

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    colors = listOf(deepBlue2, deepBlue1, deepBlue0)
                )
            )
    ) {
        FastSnowfallBackground(Modifier.fillMaxSize())

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(horizontal = 22.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(32.dp),
                colors = CardDefaults.cardColors(containerColor = cardSurface),
                elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
                border = BorderStroke(1.dp, subtleLine)
            ) {
                Column(
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 28.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Box(
                        modifier = Modifier
                            .size(72.dp)
                            .clip(RoundedCornerShape(36.dp))
                            .background(
                                Brush.linearGradient(
                                    colors = listOf(accentBlue, accentBlueDeep)
                                )
                            ),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "✋",
                            fontSize = 34.sp
                        )
                    }

                    Spacer(modifier = Modifier.height(22.dp))

                    Text(
                        text = "Жестовая презентация",
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(10.dp))
                    Text(
                        text = "Вставьте ссылку на проект — управляйте слайдами жестами через камеру.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color(0xFFC8D9F0),
                        textAlign = TextAlign.Center,
                        lineHeight = 22.sp
                    )

                    Spacer(modifier = Modifier.height(26.dp))

                    OutlinedTextField(
                        value = link,
                        onValueChange = {
                            link = it
                            error = null
                        },
                        label = {
                            Text(
                                "Ссылка на проект",
                                color = Color(0xFF9EC4EB)
                            )
                        },
                        placeholder = {
                            Text(
                                "https://…?id=ТОКЕН",
                                color = Color(0xFF5F7FA3)
                            )
                        },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Uri,
                            imeAction = ImeAction.Go
                        ),
                        keyboardActions = KeyboardActions(onGo = { validateAndSubmit() }),
                        isError = error != null,
                        supportingText = if (error != null) {
                            { Text(error!!, color = Color(0xFFFFB4B4)) }
                        } else null,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = accentBlue,
                            unfocusedBorderColor = Color(0xFF3D5F8A),
                            focusedTextColor = Color.White,
                            unfocusedTextColor = Color(0xFFE8F1FF),
                            cursorColor = accentBlue,
                            focusedLabelColor = accentBlue,
                            unfocusedLabelColor = Color(0xFF9EC4EB)
                        ),
                        shape = RoundedCornerShape(26.dp)
                    )

                    Spacer(modifier = Modifier.height(18.dp))

                    Button(
                        onClick = { validateAndSubmit() },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(54.dp),
                        shape = RoundedCornerShape(50),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = accentBlue,
                            contentColor = Color(0xFF031A33)
                        ),
                        elevation = ButtonDefaults.buttonElevation(
                            defaultElevation = 4.dp,
                            pressedElevation = 2.dp
                        )
                    ) {
                        Text(
                            text = "Открыть камеру",
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                    }

                    Spacer(modifier = Modifier.height(18.dp))

                    Text(
                        text = "Сведите указательный и большой палец — рисование  ·  Кулак — очистка",
                        fontSize = 12.sp,
                        color = Color(0xFF8CAED6),
                        textAlign = TextAlign.Center,
                        lineHeight = 17.sp
                    )
                }
            }
        }
    }
}
