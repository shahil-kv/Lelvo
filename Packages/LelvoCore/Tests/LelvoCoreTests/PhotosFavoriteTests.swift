import Testing
@testable import LelvoCore

@Suite struct PhotosFavoriteTests {
    @Test func agreeingSidesChangeNothing() {
        #expect(PhotosFavorite.decide(photos: true, lastSeen: nil, library: true, noteDecides: true) == .remember)
        #expect(PhotosFavorite.decide(photos: false, lastSeen: true, library: false, noteDecides: false) == .remember)
    }

    /// A backup without a favorite says nothing: Photos is left alone, and nothing is sent until Photos changes.
    @Test func unknownLibraryValueChangesNothing() {
        #expect(PhotosFavorite.decide(photos: true, lastSeen: nil, library: nil, noteDecides: false) == .remember)
        #expect(PhotosFavorite.decide(photos: true, lastSeen: true, library: nil, noteDecides: false) == .remember)
        #expect(PhotosFavorite.decide(photos: false, lastSeen: false, library: nil, noteDecides: false) == .remember)
    }

    /// Backed up without a heart, then hearted (or unhearted) in Photos: the change reaches the other devices.
    @Test func photosChangeAfterBackupWithoutFavoriteIsSent() {
        #expect(PhotosFavorite.decide(photos: true, lastSeen: false, library: nil, noteDecides: false) == .sendNote(true))
        #expect(PhotosFavorite.decide(photos: false, lastSeen: true, library: nil, noteDecides: false) == .sendNote(false))
    }

    /// The owner's case: unfavorited on the Mac, the iPhone's Photos still has the heart.
    @Test func aChangeFromAnotherDeviceReachesPhotos() {
        #expect(PhotosFavorite.decide(photos: true, lastSeen: nil, library: false, noteDecides: true) == .setInPhotos(false))
        #expect(PhotosFavorite.decide(photos: true, lastSeen: true, library: false, noteDecides: true) == .setInPhotos(false))
        #expect(PhotosFavorite.decide(photos: false, lastSeen: false, library: true, noteDecides: true) == .setInPhotos(true))
    }

    /// A heart changed in the Photos app is newer than what Photos had last time, so it goes to the other devices.
    @Test func aChangeInPhotosIsSent() {
        #expect(PhotosFavorite.decide(photos: true, lastSeen: false, library: false, noteDecides: true) == .sendNote(true))
        #expect(PhotosFavorite.decide(photos: false, lastSeen: true, library: true, noteDecides: false) == .sendNote(false))
        // First check, no note: Photos differs from the backup, so the user changed it there.
        #expect(PhotosFavorite.decide(photos: true, lastSeen: nil, library: false, noteDecides: false) == .sendNote(true))
    }

    /// Two devices, each with the photo in Photos, stay the same through changes on either side.
    @Test func twoDevicesFollowEachOther() {
        struct Device { var photos: Bool; var lastSeen: Bool? }
        var library = true                       // the Telegram library's value after the newest note
        var phone = Device(photos: true, lastSeen: nil), mac = Device(photos: true, lastSeen: nil)

        func check(_ d: inout Device) {
            switch PhotosFavorite.decide(photos: d.photos, lastSeen: d.lastSeen, library: library, noteDecides: true) {
            case .remember: break
            case .setInPhotos(let v): d.photos = v
            case .sendNote(let v): library = v
            }
            d.lastSeen = d.photos
        }

        check(&phone); check(&mac)
        library = false                          // removed in Lelvo on the Mac, which also changes its Photos
        mac.photos = false
        check(&mac); check(&phone)
        #expect(!phone.photos && !mac.photos)
        phone.photos = true                      // hearted in the Photos app on the phone
        check(&phone); check(&mac)
        #expect(phone.photos && mac.photos && library)
        check(&phone); check(&mac)               // nothing changed: nothing happens
        #expect(phone.photos && mac.photos && library)
    }
}
