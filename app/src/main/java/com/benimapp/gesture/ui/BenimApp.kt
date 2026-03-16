package com.benimapp.gesture.ui

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.benimapp.gesture.ui.screens.CameraScreen
import com.benimapp.gesture.ui.screens.LinkInputScreen

sealed class Screen(val route: String) {
    data object LinkInput : Screen("link_input")
    data object Camera : Screen("camera/{projectLink}") {
        fun createRoute(link: String) = "camera/$link"
    }
}

@Composable
fun BenimApp(
    viewModel: AppViewModel = viewModel()
) {
    val navController = rememberNavController()
    val projectLink by viewModel.projectLink.collectAsState()

    NavHost(
        navController = navController,
        startDestination = Screen.LinkInput.route
    ) {
        composable(Screen.LinkInput.route) {
            LinkInputScreen(
                onLinkSubmitted = { link ->
                    viewModel.setProjectLink(link)
                    navController.navigate(Screen.Camera.createRoute(Uri.encode(link))) {
                        popUpTo(Screen.LinkInput.route) { inclusive = true }
                    }
                }
            )
        }
        composable(Screen.Camera.route) { backStackEntry ->
            val encodedLink = backStackEntry.arguments?.getString("projectLink") ?: ""
            val link = if (encodedLink.isNotEmpty()) Uri.decode(encodedLink) else (projectLink ?: "")
            CameraScreen(
                projectLink = link,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
