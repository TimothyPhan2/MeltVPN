#!/usr/bin/env bash
set -euo pipefail

# ============================================
#  AWS OpenVPN Cluster Teardown Script
# ============================================
# Cleans up resources created by create_vpn_cluster.sh
# Reads state from: ./vpn_infrastructure.env
# ============================================

STATE_FILE="./vpn_infrastructure.env"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "❌ State file $STATE_FILE not found. Cannot determine resources to delete." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

# Confirmation Prompt
confirm="${1:-}"
if [[ "$confirm" != "--yes" ]]; then
  echo "⚠️  WARNING: You are about to DESTROY the VPN Cluster infrastructure."
  echo "   - Region: ${REGION:-unknown}"
  echo "   - Stack ID: ${STACK_ID:-unknown}"
  echo "   - This will delete 3 EC2 Instances, 3 Elastic IPs, VPC, Subnets, IGW, and Key Pairs."
  echo ""
  read -r -p "Are you sure? Type 'DESTROY' to proceed: " ans
  [[ "$ans" == "DESTROY" ]] || { echo "Aborted."; exit 1; }
fi

echo "🔥 Initiating Teardown..."

# 1. Terminate Instances
echo "--- Terminating EC2 Instances ---"
INSTANCE_IDS=""
# Check for Node 1, 2, and 3 IDs
if [[ -n "${NODE_1_ID:-}" ]]; then INSTANCE_IDS="$INSTANCE_IDS $NODE_1_ID"; fi
if [[ -n "${NODE_2_ID:-}" ]]; then INSTANCE_IDS="$INSTANCE_IDS $NODE_2_ID"; fi
if [[ -n "${NODE_3_ID:-}" ]]; then INSTANCE_IDS="$INSTANCE_IDS $NODE_3_ID"; fi

if [[ -n "$INSTANCE_IDS" ]]; then
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS >/dev/null
  echo "   - Termination signal sent to: $INSTANCE_IDS"
  echo "   - Waiting for instances to shut down..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
  echo "✅ Instances Terminated"
else
  echo "   - No instances found in state file."
fi

# 2. Release Elastic IPs
echo "--- Releasing Elastic IPs ---"
# We search for EIPs by the tag we applied during creation (StackId)
# This is safer than relying just on the state file variables if the loop failed halfway
EIP_ALLOC_IDS=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" \
  --query "Addresses[*].AllocationId" --output text)

if [[ -n "$EIP_ALLOC_IDS" && "$EIP_ALLOC_IDS" != "None" ]]; then
  for alloc_id in $EIP_ALLOC_IDS; do
    echo "   - Releasing EIP: $alloc_id"
    aws ec2 release-address --region "$REGION" --allocation-id "$alloc_id" || echo "     (Warning: Failed to release $alloc_id)"
  done
  echo "✅ Elastic IPs Released"
else
  echo "   - No Elastic IPs found with StackId=$STACK_ID"
fi

# 3. Delete Security Groups
echo "--- Deleting Security Group ---"
# We must wait a moment for instance termination to fully register so the SG isn't "in use"
# Sometimes AWS is slow to update the dependency map
if [[ -n "${SG_ID:-}" ]]; then
  echo "   - Attempting to delete SG: $SG_ID (Retrying if dependency error...)"
  count=0
  while true; do
    if aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null; then
      echo "✅ Security Group Deleted"
      break
    fi
    sleep 5
    count=$((count+1))
    if [[ $count -ge 12 ]]; then # Wait up to 60 seconds
      echo "❌ Failed to delete SG (Timed out waiting for dependency release). You may need to delete it manually."
      break
    fi
    echo -n "."
  done
fi

# 4. Delete Subnets
echo "--- Deleting Subnets ---"
# Find subnets by StackId tag to ensure we get all 3
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" \
  --query "Subnets[*].SubnetId" --output text)

if [[ -n "$SUBNET_IDS" && "$SUBNET_IDS" != "None" ]]; then
  for subnet_id in $SUBNET_IDS; do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet_id"
    echo "   - Deleted Subnet: $subnet_id"
  done
  echo "✅ Subnets Deleted"
fi

# 5. Delete Route Table
echo "--- Deleting Route Table ---"
# Find RTBs by StackId
RTB_IDS=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" \
  --query "RouteTables[*].RouteTableId" --output text)

if [[ -n "$RTB_IDS" && "$RTB_IDS" != "None" ]]; then
  for rtb_id in $RTB_IDS; do
    # Don't delete the main route table (it gets deleted with VPC), check first
    IS_MAIN=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rtb_id" --query "RouteTables[0].Associations[?Main].Main" --output text)
    if [[ "$IS_MAIN" != "True" ]]; then
       aws ec2 delete-route-table --region "$REGION" --route-table-id "$rtb_id"
       echo "   - Deleted Route Table: $rtb_id"
    fi
  done
fi

# 6. Detach & Delete Internet Gateway
echo "--- Deleting Internet Gateway ---"
# Find IGW by StackId
IGW_IDS=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" \
  --query "InternetGateways[*].InternetGatewayId" --output text)

if [[ -n "$IGW_IDS" && "$IGW_IDS" != "None" ]]; then
  for igw_id in $IGW_IDS; do
    if [[ -n "${VPC_ID:-}" ]]; then
      aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id" --vpc-id "$VPC_ID" || true
    fi
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw_id"
    echo "   - Deleted IGW: $igw_id"
  done
fi

# 7. Delete VPC
echo "--- Deleting VPC ---"
if [[ -n "${VPC_ID:-}" ]]; then
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID"
  echo "✅ VPC Deleted: $VPC_ID"
fi

# 8. Delete Key Pair
echo "--- Deleting Key Pair ---"
if [[ -n "${KEY_NAME:-}" ]]; then
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
  echo "✅ Key Pair Deleted from AWS"
fi

if [[ -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]]; then
  rm "$KEY_FILE"
  echo "✅ Local Key File Deleted"
fi

# Cleanup State File
rm "$STATE_FILE"
echo "================================================"
echo "🎉 TEARDOWN COMPLETE"
echo "================================================"