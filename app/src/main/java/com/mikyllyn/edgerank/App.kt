package com.mikyllyn.edgerank

import android.app.Application

class App : Application() {

    override fun onCreate() {
        super.onCreate()
        instance = this
        try {
            server = WebServer(PORT)
            server?.start(SOCKET_TIMEOUT, false)
        } catch (e: Exception) {
            // Port busy or already started — WebView will surface the error.
        }
    }

    companion object {
        const val PORT = 8088
        const val SOCKET_TIMEOUT = 60_000
        lateinit var instance: App
            private set
        @Volatile
        var server: WebServer? = null
    }
}
