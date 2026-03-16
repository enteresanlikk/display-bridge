package com.displaybridge.client.render

import android.content.Context
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import com.displaybridge.client.model.DeviceConfig

/**
 * Custom SurfaceView for displaying the remote screen.
 *
 * Maintains the correct aspect ratio based on the DeviceConfig and
 * notifies the DisplayRenderer when the surface is created or destroyed.
 */
class DisplaySurfaceView(
    context: Context,
    private val renderer: DisplayRenderer,
    private val config: DeviceConfig? = null
) : SurfaceView(context), SurfaceHolder.Callback {

    companion object {
        private const val TAG = "DisplaySurfaceView"
    }

    init {
        holder.addCallback(this)
        // Keep the surface buffer the same size as the content for performance
        if (config != null) {
            holder.setFixedSize(config.width, config.height)
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        Log.i(TAG, "Surface created")
        renderer.setSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        Log.i(TAG, "Surface changed: ${width}x${height}, format=$format")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        Log.i(TAG, "Surface destroyed")
        renderer.onSurfaceDestroyed()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val cfg = config
        if (cfg == null) {
            super.onMeasure(widthMeasureSpec, heightMeasureSpec)
            return
        }

        val availableWidth = MeasureSpec.getSize(widthMeasureSpec)
        val availableHeight = MeasureSpec.getSize(heightMeasureSpec)

        val aspectRatio = cfg.width.toFloat() / cfg.height.toFloat()

        val measuredWidth: Int
        val measuredHeight: Int

        // Fit within available space while maintaining aspect ratio
        if (availableWidth.toFloat() / availableHeight.toFloat() > aspectRatio) {
            // Available space is wider than content: height-limited
            measuredHeight = availableHeight
            measuredWidth = (availableHeight * aspectRatio).toInt()
        } else {
            // Available space is taller than content: width-limited
            measuredWidth = availableWidth
            measuredHeight = (availableWidth / aspectRatio).toInt()
        }

        setMeasuredDimension(measuredWidth, measuredHeight)
    }
}
