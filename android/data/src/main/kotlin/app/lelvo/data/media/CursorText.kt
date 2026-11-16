package app.lelvo.data.media

import android.database.Cursor

/**
 * A text column, or a number written out as text.
 *
 * MediaStore's bucket id is a number on some phones and text on others. Calling [Cursor.getString] on a number
 * throws, and that throw used to abandon the whole library listing.
 */
internal fun Cursor.text(index: Int): String? {
    if (isNull(index)) return null
    return when (getType(index)) {
        Cursor.FIELD_TYPE_STRING -> getString(index)
        Cursor.FIELD_TYPE_INTEGER -> getLong(index).toString()
        Cursor.FIELD_TYPE_FLOAT -> getDouble(index).toString()
        else -> null
    }
}
