import Foundation
import Testing
@testable import GlanceCore

@Test func catchesCommonSecrets() {
  let secrets = [
    "aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE",
    "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ",
    "gh auth login --with-token github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW",
    "curl -H 'x-api-key: sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789'",
    "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx python run.py",
    "curl -d token=xoxb-123456789012-abcdefghijkl https://slack.com/api",
    "stripe login --api-key sk_live_abcdefghijklmnop1234",
    "export MAPS=AIzaSyA-abcdefghijklmnopqrstuvwxyz0123456",
    "echo '-----BEGIN RSA PRIVATE KEY-----' > k",
    "export DB_PASSWORD=hunter2",
    "MY_SECRET=abc ./run",
    "npm config set //registry.npmjs.org/:_authToken=npm_abc",
    "psql --password=hunter2",
    "mysql -u root -phunter2 db",
    "curl -H 'Authorization: Bearer abc.def.ghi' https://api.example.com",
    "export apikey=abcdef",
  ]
  for command in secrets {
    #expect(SecretFilter.containsSecret(command), "\(command)")
  }
}

@Test func leavesOrdinaryCommandsAlone() {
  for command in ["git push", "export PATH=$PATH:/opt/bin", "ls -p", "echo password", "mysql -u root -p db",
                  "grep -r TOKEN src", "cat ~/.ssh/config", "git commit -m 'rotate the secret later'",
                  "kubectl get secrets", "sk-learn install", "docker login"] {
    #expect(!SecretFilter.containsSecret(command), "\(command)")
  }
}

@Test func redactsOnlyTheSecret() {
  #expect(SecretFilter.redact("export DB_PASSWORD=hunter2 && make") == "export DB_PASSWORD=‹redacted› && make")
  #expect(SecretFilter.redact("curl -H 'Authorization: Bearer abc.def' x") == "curl -H 'Authorization: ‹redacted›' x")
  #expect(SecretFilter.redact("git push") == "git push")
}
