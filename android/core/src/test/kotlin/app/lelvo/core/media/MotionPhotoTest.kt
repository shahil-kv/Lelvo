package app.lelvo.core.media

import kotlin.test.assertEquals
import kotlin.test.assertNull
import org.junit.jupiter.api.Test

class MotionPhotoTest {
    private val jpeg = ByteArray(1000) { 0x11 }
    private val mp4 = byteArrayOf(0, 0, 0, 0x18) + "ftypmp42".toByteArray() + ByteArray(500) { 0x22 }

    private fun reader(file: ByteArray) = MotionPhoto.Reader { offset, length ->
        file.copyOfRange(offset.toInt(), minOf(file.size, offset.toInt() + length))
    }

    private fun withXmp(xmp: String, tail: ByteArray): ByteArray = xmp.toByteArray() + jpeg + tail

    @Test fun cameraXmpV1() {
        val xmp = """<x:xmpmeta><rdf:Description Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1">
            <Container:Directory><rdf:Seq>
            <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/></rdf:li>
            <rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="${mp4.size}"/></rdf:li>
            </rdf:Seq></Container:Directory></rdf:Description></x:xmpmeta>"""
        val file = withXmp(xmp, mp4)
        assertEquals(MotionPhoto.Video((file.size - mp4.size).toLong(), mp4.size.toLong()), MotionPhoto.find(file.size.toLong(), reader(file)))
    }

    @Test fun oldMicroVideoWithOtherPrefix() {
        val xmp = """<rdf:Description xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" GCamera:MicroVideo="1"
            GCamera:MicroVideoVersion="1" GCamera:MicroVideoOffset="${mp4.size}"/>"""
        val file = withXmp(xmp, mp4)
        assertEquals((file.size - mp4.size).toLong(), MotionPhoto.find(file.size.toLong(), reader(file))?.start)
    }

    @Test fun elementFormXmp() {
        val xmp = "<GCamera:MicroVideo>1</GCamera:MicroVideo><GCamera:MicroVideoOffset>${mp4.size}</GCamera:MicroVideoOffset>"
        val file = withXmp(xmp, mp4)
        assertEquals((file.size - mp4.size).toLong(), MotionPhoto.find(file.size.toLong(), reader(file))?.start)
    }

    @Test fun wrongOffsetIsNeverPlayed() {
        val xmp = """GCamera:MicroVideo="1" GCamera:MicroVideoOffset="${mp4.size + 7}""""
        val file = withXmp(xmp, mp4)
        assertNull(MotionPhoto.find(file.size.toLong(), reader(file)))
    }

    @Test fun plainPhotoIsNotMotion() {
        val file = withXmp("""<rdf:Description GCamera:MicroVideo="0"/>""", mp4)
        assertNull(MotionPhoto.find(file.size.toLong(), reader(file)))
        assertNull(MotionPhoto.find(jpeg.size.toLong(), reader(jpeg)))
    }

    @Test fun samsungTrailer() {
        val name = "MotionPhoto_Data".toByteArray()
        val entry = byteArrayOf(0, 0, 0x30, 0x0a) + le(name.size) + name + mp4
        val body = jpeg + entry
        val dirStart = body.size
        val back = dirStart - jpeg.size
        val dir = "SEFH".toByteArray() + le(106) + le(1) + byteArrayOf(0, 0, 0x30, 0x0a) + le(back) + le(entry.size)
        val file = body + dir + le(dir.size) + "SEFT".toByteArray()
        val video = MotionPhoto.find(file.size.toLong(), reader(file))
        assertEquals(MotionPhoto.Video((jpeg.size + 8 + name.size).toLong(), mp4.size.toLong()), video)
    }

    private fun le(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
}
