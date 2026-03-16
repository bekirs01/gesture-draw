package com.benimapp.gesture

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.benimapp.gesture.ui.BenimApp
import com.benimapp.gesture.ui.theme.BenimAppTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            BenimAppTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    BenimApp()
                }
            }
        }
    }
}
