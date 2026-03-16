package com.benimapp.gesture.ui

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class AppViewModel : ViewModel() {
    private val _projectLink = MutableStateFlow<String?>(null)
    val projectLink: StateFlow<String?> = _projectLink.asStateFlow()

    fun setProjectLink(link: String) {
        _projectLink.value = link
    }
}
