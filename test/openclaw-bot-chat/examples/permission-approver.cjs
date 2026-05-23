/**
 * 权限审批示例：
 * - 群组/频道默认拒绝，需用户在 allowlist 才放行
 * - DM 默认允许
 */

const APPROVED_USERS = new Set([
  "user_admin_001",
  "user_ops_002",
]);

module.exports = {
  async approve(request) {
    const channelType = request?.channel?.type;
    const userId = request?.message?.from_id;

    if (channelType === "dm") {
      return { approved: true, reason: "dm-default-allow" };
    }

    if (userId && APPROVED_USERS.has(userId)) {
      return { approved: true, reason: "approved-user" };
    }

    return {
      approved: false,
      reason: "approval-required",
      notify_user: true,
      notify_message: "当前频道未通过机器人权限审批，请联系管理员授权后再试。",
    };
  },
};
