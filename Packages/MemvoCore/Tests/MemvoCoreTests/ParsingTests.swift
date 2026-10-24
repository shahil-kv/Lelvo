import Foundation
import Testing
import MemvoCore

@Suite struct BotAPIParsingTests {
    @Test func parsesSendDocumentResult() throws {
        let json = """
        {"ok":true,"result":{"message_id":1234,"date":1700000000,
          "chat":{"id":-1001234567890,"title":"My Backup","type":"channel"},
          "caption":"#cloudgallery id:X role:original",
          "document":{"file_name":"IMG_0001.HEIC","mime_type":"image/heic","file_id":"BQACAgQAAx0","file_unique_id":"AgADxyz","file_size":2345678}}}
        """
        let msg = try TelegramResponseParser.parse(TGMessage.self, data: Data(json.utf8), statusCode: 200)
        #expect(msg.messageId == 1234)
        #expect(msg.chat.type == "channel")
        let remote = try RemoteFile(message: msg)
        #expect(remote == RemoteFile(messageId: 1234, fileId: "BQACAgQAAx0", fileUniqueId: "AgADxyz", size: 2345678))
    }

    @Test func parsesRateLimit() {
        let json = #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 17","parameters":{"retry_after":17}}"#
        #expect(throws: TelegramError.rateLimited(retryAfter: 17)) {
            try TelegramResponseParser.parse(TGMessage.self, data: Data(json.utf8), statusCode: 429)
        }
    }

    @Test func parsesApiError() {
        let json = #"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#
        #expect(throws: TelegramError.api(code: 400, description: "Bad Request: chat not found")) {
            try TelegramResponseParser.parse(TGChat.self, data: Data(json.utf8), statusCode: 400)
        }
    }

    @Test func nonJSONErrorMapsToHTTP() {
        #expect(throws: TelegramError.http(status: 502)) {
            try TelegramResponseParser.parse(TGChat.self, data: Data("<html>Bad gateway</html>".utf8), statusCode: 502)
        }
        #expect(throws: TelegramError.rateLimited(retryAfter: 5)) {
            try TelegramResponseParser.parse(TGChat.self, data: Data(), statusCode: 429)
        }
    }

    @Test func parsesUpdatesAndFindsChats() throws {
        let json = """
        {"ok":true,"result":[
          {"update_id":1,"channel_post":{"message_id":5,"date":1,"chat":{"id":-1001111111111,"title":"Photos","type":"channel"},"text":"hi"}},
          {"update_id":2,"my_chat_member":{"chat":{"id":-1002222222222,"title":"Group","type":"supergroup"},"from":{"id":1,"is_bot":false,"first_name":"A"},"date":1,
             "old_chat_member":{"status":"left"},"new_chat_member":{"status":"administrator"}}},
          {"update_id":3,"message":{"message_id":9,"date":1,"chat":{"id":42,"type":"private","first_name":"Me"},"text":"/start"}}
        ]}
        """
        let updates = try TelegramResponseParser.parse([TGUpdate].self, data: Data(json.utf8), statusCode: 200)
        #expect(updates.count == 3)
        #expect(updates[0].chat?.id == -1001111111111)
        #expect(updates[1].chat?.type == "supergroup")
        #expect(updates.compactMap(\.chat).filter(\.isChannelOrGroup).count == 2)
    }

    @Test func parsesGetChatWithPinnedIndex() throws {
        let json = """
        {"ok":true,"result":{"id":-1001234567890,"type":"channel","title":"Backup",
          "pinned_message":{"message_id":77,"date":2,"chat":{"id":-1001234567890,"type":"channel"},
            "document":{"file_name":"cloudgallery-index.cgx","file_id":"IDX","file_unique_id":"U","file_size":1000}}}}
        """
        let chat = try TelegramResponseParser.parse(TGChat.self, data: Data(json.utf8), statusCode: 200)
        #expect(chat.pinnedMessage?.value.document?.fileName == IndexCodec.pinnedFileName)
        #expect(chat.pinnedMessage?.value.messageId == 77)
    }

    @Test func parsesChatMemberRights() throws {
        let json = """
        {"ok":true,"result":{"status":"administrator","user":{"id":1,"is_bot":true,"first_name":"b"},
          "can_post_messages":true,"can_edit_messages":true,"can_delete_messages":true,"can_be_edited":false}}
        """
        let member = try TelegramResponseParser.parse(TGChatMember.self, data: Data(json.utf8), statusCode: 200)
        let channel = BotPermissionReport(member: member, chatType: "channel")
        #expect(channel.isSufficient)
        let noDelete = BotPermissionReport(member: TGChatMember(status: "administrator", canPostMessages: true,
                                                                canEditMessages: true, canDeleteMessages: false,
                                                                canPinMessages: nil), chatType: "channel")
        #expect(noDelete.missing == ["delete messages"])
        let notAdmin = BotPermissionReport(member: TGChatMember(status: "member", canPostMessages: nil, canEditMessages: nil,
                                                                canDeleteMessages: nil, canPinMessages: nil), chatType: "supergroup")
        #expect(!notAdmin.isSufficient)
        #expect(notAdmin.missing.first == "administrator")
    }

    @Test func parsesGetFile() throws {
        let json = #"{"ok":true,"result":{"file_id":"A","file_unique_id":"B","file_size":123,"file_path":"documents/file_1.heic"}}"#
        let file = try TelegramResponseParser.parse(TGFile.self, data: Data(json.utf8), statusCode: 200)
        #expect(file.filePath == "documents/file_1.heic")
        #expect(file.fileSize == 123)
    }

    @Test func multipartBodyIsWellFormed() throws {
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent(UUID().uuidString), dst = dir.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try Data("PAYLOAD".utf8).write(to: src)
        let body = MultipartBody(boundary: "B")
        let size = try body.write(fields: [("chat_id", "-100")],
                                  file: .init(fieldName: "document", fileName: "a.jpg", mimeType: "image/jpeg", fileURL: src), to: dst)
        let text = String(decoding: try Data(contentsOf: dst), as: UTF8.self)
        #expect(Int64(text.utf8.count) == size)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n-100\r\n"))
        #expect(text.contains("filename=\"a.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nPAYLOAD\r\n--B--\r\n"))
    }

    @Test func redactsSecrets() {
        let line = "POST https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ/sendDocument chat -1001234567890"
        let out = Redactor.redact(line)
        #expect(!out.contains("AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ"))
        #expect(!out.contains("1234567890"))
        #expect(out.contains("<bot-token>"))
        #expect(Redactor.redact("my secret passphrase", extraSecrets: ["secret passphrase"]) == "my <redacted>")
    }
}
