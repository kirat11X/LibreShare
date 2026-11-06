package dev.libreshare.libreshare_app

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Quick Settings Tile allowing one-tap toggle of LibreShare background reception.
 *
 * Requires BIND_QUICK_SETTINGS_TILE permission and android:exported="true" per Android OS API contract.
 */
@RequiresApi(Build.VERSION_CODES.N)
class ReceiveTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = if (ReceiveService.isRunning) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val tile = qsTile ?: return
        if (ReceiveService.isRunning) {
            val stopIntent = Intent(this, ReceiveService::class.java).apply {
                action = ReceiveService.ACTION_STOP
            }
            startService(stopIntent)
            tile.state = Tile.STATE_INACTIVE
        } else {
            val startIntent = Intent(this, ReceiveService::class.java).apply {
                action = ReceiveService.ACTION_START
                putExtra(ReceiveService.EXTRA_TITLE, "LibreShare")
                putExtra(ReceiveService.EXTRA_BODY, "Ready to receive files")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(startIntent)
            } else {
                startService(startIntent)
            }
            tile.state = Tile.STATE_ACTIVE
        }
        tile.updateTile()
    }
}
