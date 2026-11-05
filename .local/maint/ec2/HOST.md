# OSv timer-deref (crash 2) debug host (2026-10-20)
Instance: i-0b211d50b485a4557 (m5d.metal, KVM, local NVMe) Fedora 41 ami-0594a9de6593a61ef
IP: 18.220.154.83  User: fedora  Key: .local/maint/ec2/osv-validate.pem  SG: sg-0e8982cf031560c67
Account: kiwi 505435643998. Timer: shutdown -h +1440.
Purpose: root-cause+fix crash 2 (sched::timer_list::fired near-null 0x30 deref under pgbench -c8)
  on the fixed merge branch 3ce446a1a (crash 1 already fixed). Then full gate pgbench -c8 0-failed.
Teardown: aws ec2 terminate-instances --instance-ids i-0b211d50b485a4557
