package com.maxrave.simpmusic.access

/** Identificador estable del dispositivo. Cadena vacía si la plataforma no lo da. */
expect fun accessDeviceId(): String

/** Nombre legible del dispositivo, para mostrarlo en el panel admin. */
expect fun accessDeviceName(): String
