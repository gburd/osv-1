# HARD SECURITY RULE (operator directive 2026-09-18): NEVER a world-open port 22 in a burner account.

## THE RULE
NEVER authorize 0.0.0.0/0 (or ::/0) ingress on tcp/22 (or any port) in any burner AWS account. A world-open
SSH rule gets the account FLAGGED and CLOSED by AWS abuse detection. This is zero-tolerance.

## THE CORRECT PATTERN when creating a bench SG
1. Get my current public IP: curl -s https://checkip.amazonaws.com
2. authorize-security-group-ingress ... --port 22 --cidr <MYIP>/32   (NEVER 0.0.0.0/0)
3. Verify: describe-security-groups ... query for any IpRanges containing 0.0.0.0/0 -> must be EMPTY.
If the IP changes: revoke the stale /32, authorize the new /32, re-verify no 0.0.0.0/0.

## INCIDENT (fixed 2026-09-18)
On creating hotdog's osv-bench SG (sg-0a0fec26afe57cd43) I authorized 22 from 0.0.0.0/0 - a security
failure that would flag the account. REMEDIATED: revoked the world-open rule (sgr-0b3078a9178a04ce6),
added 22 from 73.4.58.126/32 only (sgr-050172621123609e7). Swept all of hotdog (us-east-2/1, us-west-2) +
the default SG -> ZERO world-open ingress remaining. This must never recur.

## STANDING: every future SG-create in ANY burner account uses the /32 pattern. Grep before/after launch:
##   aws ec2 describe-security-groups --query 'SecurityGroups[?...contains(IpRanges,`0.0.0.0/0`)]'  == empty.
