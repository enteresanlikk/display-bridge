package com.displaybridge.client.render

import android.util.Log
import android.view.Surface

/**
 * Manages the render surface for decoded video frames.
 *
 * Acts as a bridge between the hardware decoder output and the
 * SurfaceView display. The decoder renders directly to the Surface
 * provided by this manager for zero-copy output.
 */
class DisplayRenderer {

    companion object {
        private const val TAG = "DisplayRenderer"
    }

    private var surface: Surface? = null

    @Volatile
    private var isSurfaceReady = false

    /**
     * Listener interface for surface state changes.
     */
    interface SurfaceStateListener {
        fun onSurfaceReady(surface: Surface)
        fun onSurfaceDestroyed()
    }

    private var listener: SurfaceStateListener? = null

    /**
     * Sets the listener for surface state changes.
     */
    fun setSurfaceStateListener(listener: SurfaceStateListener?) {
        this.listener = listener
    }

    /**
     * Sets the render surface. Called when the SurfaceView's surface is created.
     *
     * @param surface The Surface to render decoded frames to.
     */
    fun setSurface(surface: Surface) {
        Log.i(TAG, "Surface set")
        this.surface = surface
        isSurfaceReady = true
        listener?.onSurfaceReady(surface)
    }

    /**
     * Returns the current render surface, or null if not available.
     */
    fun getSurface(): Surface? = surface

    /**
     * Returns whether the surface is ready for rendering.
     */
    fun isSurfaceReady(): Boolean = isSurfaceReady

    /**
     * Called when the surface is destroyed. Clears the reference.
     */
    fun onSurfaceDestroyed() {
        Log.i(TAG, "Surface destroyed")
        isSurfaceReady = false
        surface = null
        listener?.onSurfaceDestroyed()
    }
}
