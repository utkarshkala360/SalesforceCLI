@IsTest(SeeAllData=false)
private class AgentResolverTest {
  private static final String MOBILE = '9876512345';

  private static User agent() {
    Profile p = [SELECT Id FROM Profile WHERE Id = :UserInfo.getProfileId()];
    String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    User u = new User(
      FirstName = 'Resolver',
      LastName = 'Agent' + unique,
      Email = 'resolver.agent' + unique + '@example.com',
      Username = 'resolver.agent' + unique + '@example.com.test',
      Alias = 'ragent',
      MobilePhone = '+91 ' + MOBILE,
      ProfileId = p.Id,
      TimeZoneSidKey = 'Asia/Kolkata',
      LocaleSidKey = 'en_IN',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    insert u;
    return [SELECT Id, Name, Email FROM User WHERE Id = :u.Id];
  }

  @IsTest
  static void resolvesByEmail() {
    User u = agent();
    System.assertEquals(
      u.Id,
      AgentResolver.resolve(new Map<String, Object>{ 'agentEmail' => u.Email })
    );
    System.assertEquals(
      u.Id,
      AgentResolver.resolve(new Map<String, Object>{ 'agent_email' => u.Email })
    );
  }

  @IsTest
  static void resolvesByName() {
    User u = agent();
    System.assertEquals(
      u.Id,
      AgentResolver.resolve(
        new Map<String, Object>{ 'agentName' => ' ' + u.Name + ' ' }
      )
    );
  }

  @IsTest
  static void resolvesByMobile() {
    User u = agent();
    System.assertEquals(
      u.Id,
      AgentResolver.resolve(
        new Map<String, Object>{
          'agentName' => 'Nobody Here',
          'agentNumber' => '0' + MOBILE
        }
      )
    );
  }

  @IsTest
  static void emailTakesPriorityOverName() {
    User u = agent();
    System.assertEquals(
      u.Id,
      AgentResolver.resolve(
        new Map<String, Object>{
          'agentEmail' => u.Email,
          'agentName' => UserInfo.getName()
        }
      )
    );
  }

  @IsTest
  static void returnsNullWhenNoMatch() {
    System.assertEquals(null, AgentResolver.resolve(null));
    System.assertEquals(null, AgentResolver.resolve(new Map<String, Object>()));
    System.assertEquals(
      null,
      AgentResolver.resolve(
        new Map<String, Object>{
          'agentEmail' => 'nobody@example.invalid',
          'agentName' => 'Nobody Here',
          'agentNumber' => '123'
        }
      )
    );
  }
}
