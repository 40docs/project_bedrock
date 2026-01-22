# CONFIDENTIAL: System Credentials

**Classification: RESTRICTED**
**For IT Department Use Only**

---

## AWS Production Credentials

**Account ID:** 123456789012

### Service Account: bedrock-prod
- **Access Key ID:** AKIAIOSFODNN7EXAMPLE
- **Secret Access Key:** wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

### Service Account: s3-backup
- **Access Key ID:** AKIAI44QH8DHBEXAMPLE
- **Secret Access Key:** je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY

---

## Database Credentials

### Production MySQL
- **Host:** prod-db.disney-corp.internal
- **Port:** 3306
- **Username:** admin
- **Password:** DisneyMagic2024!Prod

### Staging PostgreSQL
- **Host:** staging-db.disney-corp.internal
- **Port:** 5432
- **Username:** app_user
- **Password:** StagingPass123!

---

## API Keys

### Stripe Payment Processing
- **Live Key:** sk_live_51ABC123XYZ789DEF000
- **Test Key:** sk_test_51ABC123XYZ789DEF000

### SendGrid Email
- **API Key:** SG.abcdefghijklmnop.qrstuvwxyz123456789

### Slack Webhook
- **Webhook URL:** https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX

---

## SSH Keys

### Production Bastion Host
```
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB5Uxe8P8S8f1EXAMPLE
... (truncated for security) ...
-----END RSA PRIVATE KEY-----
```

---

## VPN Credentials

| User | Username | Password | 2FA Seed |
|------|----------|----------|----------|
| Mickey Mouse | mmouse | VPNaccess2024! | JBSWY3DPEHPK3PXP |
| Donald Duck | dduck | QuackVPN123! | GEZDGNBVGY3TQOJQ |

---

*NEVER share these credentials. Rotate immediately if compromised.*
