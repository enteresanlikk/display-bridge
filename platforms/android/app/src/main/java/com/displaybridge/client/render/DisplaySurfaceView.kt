package com.displaybridge.client.render

import android.content.Context
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewConfiguration
import com.displaybridge.client.model.DeviceConfig
import com.displaybridge.client.protocol.PacketFramer
import kotlin.math.hypot

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

        // One mouse-wheel notch scrolls this fraction of the display.
        private const val WHEEL_STEP = 0.05f
    }

    /**
     * Receives pointer input to forward to the source:
     * (kind, button, x, y, dx, dy, pressure) — see PacketFramer.createInputEvent.
     *
     * Gestures: one finger taps / drags (primary button), two fingers scroll, a
     * two-finger tap is a secondary click. A pen or mouse presses immediately and
     * reports pressure and its own buttons.
     */
    var onInput: ((Int, Int, Float, Float, Float, Float, Float) -> Unit)? = null

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private var downX = 0f
    private var downY = 0f
    private var button = 0
    private var pressed = false      // a Down has been sent and not yet released
    private var scrolling = false    // a two-finger gesture is in progress
    private var scrollMoved = false  // ...and it moved far enough to be a scroll, not a tap
    private var scrollStartX = 0f
    private var scrollStartY = 0f
    private var lastScrollX = 0f
    private var lastScrollY = 0f

    private fun nx(px: Float) = if (width > 0) (px / width).coerceIn(0f, 1f) else 0f
    private fun ny(py: Float) = if (height > 0) (py / height).coerceIn(0f, 1f) else 0f

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val send = onInput ?: return super.onTouchEvent(e)
        val x = nx(e.x)
        val y = ny(e.y)

        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x
                downY = e.y
                scrolling = false
                scrollMoved = false
                if (e.getToolType(0) == MotionEvent.TOOL_TYPE_FINGER) {
                    // Hold the press back until we know this isn't the first finger
                    // of a two-finger scroll; just bring the cursor here for now.
                    button = 0
                    pressed = false
                    send(PacketFramer.INPUT_HOVER, 0, x, y, 0f, 0f, 0f)
                } else {
                    val secondary = MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_STYLUS_PRIMARY
                    button = if (e.buttonState and secondary != 0) 1 else 0
                    pressed = true
                    send(PacketFramer.INPUT_DOWN, button, x, y, 0f, 0f, e.pressure)
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> if (e.pointerCount == 2) {
                if (pressed) {
                    send(PacketFramer.INPUT_UP, button, x, y, 0f, 0f, 0f)
                    pressed = false
                }
                scrolling = true
                scrollMoved = false
                scrollStartX = (e.getX(0) + e.getX(1)) / 2
                scrollStartY = (e.getY(0) + e.getY(1)) / 2
                lastScrollX = scrollStartX
                lastScrollY = scrollStartY
            }

            MotionEvent.ACTION_MOVE -> {
                if (scrolling) {
                    if (e.pointerCount >= 2 && width > 0 && height > 0) {
                        val cx = (e.getX(0) + e.getX(1)) / 2
                        val cy = (e.getY(0) + e.getY(1)) / 2
                        if (scrollMoved || hypot(cx - scrollStartX, cy - scrollStartY) > touchSlop) {
                            scrollMoved = true
                            send(
                                PacketFramer.INPUT_SCROLL, 0, nx(downX), ny(downY),
                                (cx - lastScrollX) / width, (cy - lastScrollY) / height, 0f
                            )
                        }
                        lastScrollX = cx
                        lastScrollY = cy
                    }
                } else if (pressed) {
                    send(PacketFramer.INPUT_MOVE, button, x, y, 0f, 0f, e.pressure)
                } else if (hypot(e.x - downX, e.y - downY) > touchSlop) {
                    // The finger travelled: this is a drag, starting where it landed.
                    pressed = true
                    send(PacketFramer.INPUT_DOWN, 0, nx(downX), ny(downY), 0f, 0f, 1f)
                    send(PacketFramer.INPUT_MOVE, 0, x, y, 0f, 0f, 1f)
                }
            }

            MotionEvent.ACTION_UP -> {
                if (scrolling) {
                    if (!scrollMoved) click(send, 1)   // two-finger tap
                } else if (pressed) {
                    send(PacketFramer.INPUT_UP, button, x, y, 0f, 0f, 0f)
                } else {
                    click(send, 0)                     // plain tap
                }
                pressed = false
                scrolling = false
            }

            MotionEvent.ACTION_CANCEL -> {
                if (pressed) send(PacketFramer.INPUT_UP, button, x, y, 0f, 0f, 0f)
                pressed = false
                scrolling = false
            }
        }
        return true
    }

    private fun click(send: (Int, Int, Float, Float, Float, Float, Float) -> Unit, button: Int) {
        send(PacketFramer.INPUT_DOWN, button, nx(downX), ny(downY), 0f, 0f, 1f)
        send(PacketFramer.INPUT_UP, button, nx(downX), ny(downY), 0f, 0f, 0f)
    }

    /** Pen / mouse moving over the view without touching it. */
    override fun onHoverEvent(e: MotionEvent): Boolean {
        val send = onInput ?: return super.onHoverEvent(e)
        if (e.actionMasked == MotionEvent.ACTION_HOVER_MOVE) {
            send(PacketFramer.INPUT_HOVER, 0, nx(e.x), ny(e.y), 0f, 0f, 0f)
        }
        return true
    }

    /** Mouse wheel. */
    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        val send = onInput ?: return super.onGenericMotionEvent(e)
        if (e.actionMasked != MotionEvent.ACTION_SCROLL) return super.onGenericMotionEvent(e)
        // Android reports "scroll right" as positive; the wire format is "content moves
        // right" as positive, so the horizontal axis flips. Vertical already agrees.
        send(
            PacketFramer.INPUT_SCROLL, 0, nx(e.x), ny(e.y),
            -e.getAxisValue(MotionEvent.AXIS_HSCROLL) * WHEEL_STEP,
            e.getAxisValue(MotionEvent.AXIS_VSCROLL) * WHEEL_STEP,
            0f
        )
        return true
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
