package app.lelvo.core.format

/**
 * Keeps the favorite in the phone's gallery and in the Telegram library the same for items on this phone (iOS
 * `PhotosFavorite`, #99). MediaStore has no history Lelvo can trust for "who changed it last", so each item remembers
 * the favorite the phone had last time it was checked. When the phone still has that value, the user didn't touch it
 * there: the Telegram library's value (from the backup and the newest note) goes to the phone. When the phone changed
 * since, that is the user's newer choice: it's sent as a note, so every other device follows.
 */
object PhotosFavorite {
    sealed class Decision {
        /** They agree, or there's nothing to go by: only remember what the phone has. */
        object Remember : Decision()
        /** Set the favorite on the phone to this value. */
        data class SetOnPhone(val value: Boolean) : Decision()
        /** Send the phone's value to the other devices as a note. */
        data class SendNote(val value: Boolean) : Decision()
    }

    /**
     * [phone]: the favorite on the phone now. [lastSeen]: what it had last time, null before the first check.
     * [library]: the item's favorite in the Telegram library, null when neither its backup nor a note recorded one
     * (captions only carry `fav` when it's set; see [libraryValue]). [noteDecides]: a note (sent or waiting) sets it,
     * so [library] isn't just the backup's value.
     */
    fun decide(phone: Boolean, lastSeen: Boolean?, library: Boolean?, noteDecides: Boolean): Decision {
        if (library == null || library == phone) return Decision.Remember
        // First check: nothing says which side changed last. A note is a change made in Lelvo after the backup, so it
        // wins; without one, the phone differs from what was backed up, so the user changed it on the phone.
        if (lastSeen == null) return if (noteDecides) Decision.SetOnPhone(library) else Decision.SendNote(phone)
        return if (phone == lastSeen) Decision.SetOnPhone(library) else Decision.SendNote(phone)
    }

    /**
     * The item's favorite as iOS keeps it: a caption without `fav` and no note leaves it unknown, so a photo backed
     * up without a heart is left alone on the phone and nothing is sent for it.
     */
    fun libraryValue(favorite: Boolean, noteDecides: Boolean): Boolean? = if (favorite || noteDecides) favorite else null
}
