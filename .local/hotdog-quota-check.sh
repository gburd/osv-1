#!/usr/bin/env bash
# Poll hotdog's vCPU quota; report READY when it can host m5d.metal (>=96).
set -u
export AWS_PROFILE=hotdog
Q=$(timeout 20 aws service-quotas get-service-quota --region us-east-2 \
      --service-code ec2 --quota-code L-1216C47A --query 'Quota.Value' --output text 2>/dev/null)
echo "hotdog L-1216C47A effective vCPU quota: ${Q:-<query-failed>}"
if [ -n "${Q:-}" ] && awk "BEGIN{exit !(${Q%.*} >= 96)}"; then
  echo "READY: quota >= 96, can launch m5d.metal. Launch the adaptive-idle-spin gates run."
else
  echo "BLOCKED: quota < 96 (need >=96 for m5d.metal). Request 1152 is CASE_OPENED; await AWS grant."
fi
