# OSv stub-fix validation host (2026-10-17, FEDORA per user directive)
Account: kiwi profile (NEW account), us-east-2
Instance: i-07d8cb7a1c214ace8 (c7i.4xlarge, Fedora Cloud Base 44 ami-0955599506d6978e2)
User: fedora   Key: .local/maint/ec2/osv-validate.pem   SG: sg-0e8982cf031560c67 (ssh my /32 only)
IP: 18.188.161.255   Timer: shutdown -h +1440 (24h), parent-managed.
Validates: nvme PRP assert, faccessat NOFOLLOW, pthread_cleanup, lwext4 0002.
Teardown: aws ec2 terminate-instances --instance-ids i-07d8cb7a1c214ace8
NOTE: all build/boot/test work runs HERE on Fedora, never on floki.
