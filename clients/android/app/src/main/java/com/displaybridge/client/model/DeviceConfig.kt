package com.displaybridge.client.model

import org.json.JSONObject

data class DeviceConfig(
    val width: Int,
    val height: Int,
    val refreshRate: Int,
    val codec: String = "hevc",
    val colorSpace: String = "srgb",
    val deviceName: String? = null
) {
    fun toJson(): String {
        val json = JSONObject()
        json.put("width", width)
        json.put("height", height)
        json.put("refreshRate", refreshRate)
        json.put("codec", codec)
        json.put("colorSpace", colorSpace)
        if (deviceName != null) {
            json.put("deviceName", deviceName)
        }
        return json.toString()
    }

    companion object {
        fun fromJson(json: String): DeviceConfig {
            val obj = JSONObject(json)
            return DeviceConfig(
                width = obj.getInt("width"),
                height = obj.getInt("height"),
                refreshRate = obj.getInt("refreshRate"),
                codec = obj.optString("codec", "hevc"),
                colorSpace = obj.optString("colorSpace", "srgb"),
                deviceName = if (obj.has("deviceName")) obj.getString("deviceName") else null
            )
        }
    }
}
