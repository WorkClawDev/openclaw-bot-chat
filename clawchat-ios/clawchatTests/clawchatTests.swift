//
//  clawchatTests.swift
//  clawchatTests
//
//  Created by Changer Ding on 2026/4/12.
//

import Foundation
import Testing
@testable import clawchat

struct clawchatTests {

    @Test func groupPermissionsKeepOwnerAdminAndMemberActionsDistinct() {
        let group = UUID(), owner = UUID(), admin = UUID(), member = UUID()
        let members = [(owner, "owner"), (admin, "admin"), (member, "member")].map {
            GroupUserMember(id: UUID(), groupId: group, userId: $0.0, role: $0.1, nickname: nil, user: nil)
        }
        let ownerPermissions = GroupMemberPermissions(currentUserID: owner, members: members)
        #expect(ownerPermissions.canRename && ownerPermissions.canManageMembers)
        #expect(!ownerPermissions.canLeave && !ownerPermissions.canRemove(members[0]))
        #expect(ownerPermissions.canRemove(members[1]) && ownerPermissions.canRemove(members[2]))
        let adminPermissions = GroupMemberPermissions(currentUserID: admin, members: members)
        #expect(!adminPermissions.canRename && adminPermissions.canManageMembers && adminPermissions.canLeave)
        #expect(!adminPermissions.canRemove(members[0]) && !adminPermissions.canRemove(members[1]))
        #expect(adminPermissions.canRemove(members[2]))
        let memberPermissions = GroupMemberPermissions(currentUserID: member, members: members)
        #expect(!memberPermissions.canRename && !memberPermissions.canManageMembers && memberPermissions.canLeave)
        #expect(!members.contains { memberPermissions.canRemove($0) })
        for unknown in [UUID?.none, UUID?.some(UUID())] {
            let permissions = GroupMemberPermissions(currentUserID: unknown, members: members)
            #expect(!permissions.canRename && !permissions.canManageMembers && !permissions.canLeave)
        }
    }

    @Test func createdBotKeyDecodesOneTimeSecretWithoutListState() throws {
        let payload = Data(#"{"id":"00000000-0000-4000-8000-000000000001","key":"unit-test-only-secret","key_prefix":"unit-test","created_at":1800000000}"#.utf8)
        let response = try JSONDecoder().decode(CreatedBotKeyResponse.self, from: payload)
        #expect(response.key == "unit-test-only-secret")
    }

    @Test func createdBotKeyRequiresOneTimeSecret() throws {
        let payload = Data(#"{"id":"00000000-0000-4000-8000-000000000001"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(CreatedBotKeyResponse.self, from: payload) }
    }

    @Test func revokedBotKeyListPreservesInactiveStateWithoutSecret() throws {
        let payload = Data(#"{"id":"00000000-0000-4000-8000-000000000001","key_prefix":"unit-test","is_active":false}"#.utf8)
        let response = try JSONDecoder().decode(BotKeyResponse.self, from: payload)
        #expect(!response.isActive)
        #expect(response.key == nil)
    }

    @Test func messageContentMetaAcceptsNullValues() throws {
        let payload = """
        {
          "id": "m1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "u1",
          "sender_type": "user",
          "from": { "type": "user", "id": "u1" },
          "to": { "type": "group", "id": "g1" },
          "content": {
            "type": "image",
            "meta": {
              "asset": {
                "external_url": null
              }
            }
          }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: payload)
        let asset = message.content.meta?["asset"]?.dictionaryValue

        #expect(asset?["external_url"]?.value is NSNull)
    }

    @Test func anyCodableEncodesNullValuesAsJsonNull() throws {
        let object: [String: AnyCodable] = [
            "external_url": AnyCodable(NSNull())
        ]
        let data = try JSONEncoder().encode(object)
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)

        #expect(decoded["external_url"]?.value is NSNull)
    }

}
