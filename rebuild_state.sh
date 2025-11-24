#!/usr/bin/env bash
set -euo pipefail

# Change if needed:
REGION="${REGION:-us-west-1}"
STATE_FILE="${STATE_FILE:-./aws_vpc_stack_ids.env}"

# Helper: append KEY="VALUE" to the state file
save() { echo "$1=\"$2\"" >> "$STATE_FILE"; }

: > "$STATE_FILE"

# 1) Try to infer STACK_ID from the most recent public-ec2 (you can also: export STACK_ID=... before running)
if [[ -z "${STACK_ID:-}" ]]; then
  STACK_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=public-ec2" "Name=tag:StackId,Values=*" \
    --query "sort_by(Reservations[].Instances[], &LaunchTime)[-1].Tags[?Key=='StackId']|[0].Value" \
    --output text)
fi

if [[ -z "${STACK_ID:-}" || "$STACK_ID" == "None" ]]; then
  echo "I don’t know the StackId (couldn’t infer it). Supply it explicitly: STACK_ID=YYYYMMDDHHMMSS ./rebuild_state.sh" >&2
  exit 1
fi

echo "Rebuilding state for STACK_ID=$STACK_ID in $REGION ..."
save REGION "$REGION"
save STACK_ID "$STACK_ID"

# 2) Core network
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=app-vpc" \
  --query "Vpcs[0].VpcId" --output text)
[[ "$VPC_ID" == "None" ]] && { echo "I don’t know the VPC_ID."; exit 1; }
save VPC_ID "$VPC_ID"

PUB_SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-subnet" \
  --query "Subnets[0].SubnetId" --output text)
save PUB_SUBNET_ID "$PUB_SUBNET_ID"

PRIV_SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=private-subnet" \
  --query "Subnets[0].SubnetId" --output text)
save PRIV_SUBNET_ID "$PRIV_SUBNET_ID"

IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-igw" \
  --query "InternetGateways[0].InternetGatewayId" --output text)
save IGW_ID "$IGW_ID"

PUB_RTB_ID=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-rtb" \
  --query "RouteTables[0].RouteTableId" --output text)
save PUB_RTB_ID "$PUB_RTB_ID"

PRIV_RTB_ID=$(aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=private-rtb" \
  --query "RouteTables[0].RouteTableId" --output text)
save PRIV_RTB_ID "$PRIV_RTB_ID"

# 3) NAT gateway + its EIP
NAT_GW_ID=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-natgw" \
  --query "sort_by(NatGateways, &CreateTime)[-1].NatGatewayId" --output text)
save NAT_GW_ID "$NAT_GW_ID"

NAT_EIP_ALLOC_ID=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --nat-gateway-ids "$NAT_GW_ID" \
  --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" --output text)
save NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"

# 4) Security groups
PUBLIC_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-ssh-sg" \
  --query "SecurityGroups[0].GroupId" --output text)
save PUBLIC_SG_ID "$PUBLIC_SG_ID"

PRIVATE_SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=private-ssh-sg" \
  --query "SecurityGroups[0].GroupId" --output text)
save PRIVATE_SG_ID "$PRIVATE_SG_ID"

# 5) Key pair (local file may or may not exist—set path anyway)
KEY_NAME=$(aws ec2 describe-key-pairs --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" \
  --query "KeyPairs[0].KeyName" --output text)
save KEY_NAME "$KEY_NAME"
save KEY_FILE "./${KEY_NAME}.pem"

# 6) Instances + IPs
PUB_INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=public-ec2" \
  --query "sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId" --output text)
save PUB_INSTANCE_ID "$PUB_INSTANCE_ID"

PRIV_INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:StackId,Values=$STACK_ID" "Name=tag:Name,Values=private-ec2" \
  --query "sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId" --output text)
save PRIV_INSTANCE_ID "$PRIV_INSTANCE_ID"

PUB_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$PUB_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
save PUB_PRIVATE_IP "$PUB_PRIVATE_IP"

PRIV_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$PRIV_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
save PRIV_PRIVATE_IP "$PRIV_PRIVATE_IP"

# 7) Public EIP for the public instance
PUB_EIP_JSON=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=instance-id,Values=$PUB_INSTANCE_ID" --output json)
PUB_EIP=$(echo "$PUB_EIP_JSON" | jq -r '.Addresses[0].PublicIp' 2>/dev/null || true)
PUB_EIP_ALLOC_ID=$(echo "$PUB_EIP_JSON" | jq -r '.Addresses[0].AllocationId' 2>/dev/null || true)
PUB_EIP_ASSOC_ID=$(echo "$PUB_EIP_JSON" | jq -r '.Addresses[0].AssociationId' 2>/dev/null || true)

# If jq isn't installed, fall back to JMESPath-only calls:
if [[ -z "${PUB_EIP:-}" || "$PUB_EIP" == "null" ]]; then
  PUB_EIP=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=instance-id,Values=$PUB_INSTANCE_ID" \
    --query "Addresses[0].PublicIp" --output text 2>/dev/null || true)
  PUB_EIP_ALLOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=instance-id,Values=$PUB_INSTANCE_ID" \
    --query "Addresses[0].AllocationId" --output text 2>/dev/null || true)
  PUB_EIP_ASSOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=instance-id,Values=$PUB_INSTANCE_ID" \
    --query "Addresses[0].AssociationId" --output text 2>/dev/null || true)
fi

save PUB_EIP "$PUB_EIP"
save PUB_EIP_ALLOC_ID "$PUB_EIP_ALLOC_ID"
save PUB_EIP_ASSOC_ID "$PUB_EIP_ASSOC_ID"

echo "✅ Rewrote $STATE_FILE"
echo "Public EIP:    $PUB_EIP"
echo "Private IP:    $PRIV_PRIVATE_IP"
echo
echo "SSH (ProxyJump):"
echo "  ssh -i \"./${KEY_NAME}.pem\" -J ubuntu@${PUB_EIP} ubuntu@${PRIV_PRIVATE_IP}"
echo
echo "SSH (Agent forward):"
echo "  eval \"\$(ssh-agent -s)\" && ssh-add \"./${KEY_NAME}.pem\""
echo "  ssh -A -i \"./${KEY_NAME}.pem\" ubuntu@${PUB_EIP}"
echo "  # from the public host:"
echo "  ssh ubuntu@${PRIV_PRIVATE_IP}"

