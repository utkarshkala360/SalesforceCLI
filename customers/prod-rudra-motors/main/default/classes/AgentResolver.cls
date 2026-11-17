/*
 * Finds the Salesforce user for the agent named in a Call Anchor payload.
 * Tries email, then full name, then mobile number. Returns null when no
 * active user matches.
 */
public without sharing class AgentResolver {
  public static Id resolve(Map<String, Object> callData) {
    if (callData == null) {
      return null;
    }

    Id userId = byEmail(text(callData, 'agentEmail', 'agent_email'));
    if (userId == null)
      userId = byName(text(callData, 'agentName', 'agent_name'));
    if (userId == null)
      userId = byMobile(text(callData, 'agentNumber', 'agent_number'));
    return userId;
  }

  private static Id byEmail(String email) {
    if (String.isBlank(email)) {
      return null;
    }
    List<User> users = [
      SELECT Id
      FROM User
      WHERE Email = :email.trim() AND IsActive = TRUE
      LIMIT 1
    ];
    return users.isEmpty() ? null : users[0].Id;
  }

  private static Id byName(String name) {
    if (String.isBlank(name)) {
      return null;
    }
    List<User> users = [
      SELECT Id
      FROM User
      WHERE Name = :name.trim() AND IsActive = TRUE
      LIMIT 1
    ];
    return users.isEmpty() ? null : users[0].Id;
  }

  private static Id byMobile(String mobile) {
    String digits = String.isBlank(mobile)
      ? ''
      : mobile.replaceAll('[^0-9]', '');
    if (digits.length() < 10) {
      return null;
    }
    String last10 = digits.right(10);
    String pattern = '%' + last10.right(4);

    for (User u : [
      SELECT Id, MobilePhone
      FROM User
      WHERE MobilePhone LIKE :pattern AND IsActive = TRUE
      LIMIT 200
    ]) {
      if (u.MobilePhone.replaceAll('[^0-9]', '').right(10) == last10) {
        return u.Id;
      }
    }
    return null;
  }

  private static String text(
    Map<String, Object> data,
    String key,
    String altKey
  ) {
    Object value = data.containsKey(key) ? data.get(key) : data.get(altKey);
    return value == null ? null : String.valueOf(value);
  }
}
