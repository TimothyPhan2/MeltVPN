#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="./aws_vpc_stack_ids.env"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "State file $STATE_FILE not found. I don’t know what to delete." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

confirm="${1:-}"
if [[ "$confirm" != "--yes" ]]; then
  echo "About to delete ALL resources recorded in $STATE_FILE (StackId=$STACK_ID) in REGION=$REGION."
  echo "This includes EC2 instances, EIPs (public + NAT), NAT GW, RTBs, IGW, subnets, SGs, VPC, and the local key file."
  read -r -p "Proceed? (type YES): " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
fi

# ---- Terminate instances ----
if [[ -n "${PUB_INSTANCE_ID:-}" || -n "${PRIV_INSTANCE_ID:-}" ]]; then
  ids=()
  [[ -n "${PUB_INSTANCE_ID:-}" ]] && ids+=("$PUB_INSTANCE_ID")
  [[ -n "${PRIV_INSTANCE_ID:-}" ]] && ids+=("$PRIV_INSTANCE_ID")
  if [[ ${#ids[@]} -gt 0 ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids "${ids[@]}" >/dev/null || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${ids[@]}" || true
    echo "Instances terminated: ${ids[*]}"
  fi
fi

# ---- Disassociate & release public instance EIP ----
if [[ -n "${PUB_EIP_ALLOC_ID:-}" ]]; then
  ASSOC_ID=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$PUB_EIP_ALLOC_ID" \
    --query "Addresses[0].AssociationId" --output text 2>/dev/null || echo "None")
  if [[ "$ASSOC_ID" != "None" && -n "$ASSOC_ID" ]]; then
    aws ec2 disassociate-address --region "$REGION" --association-id "$ASSOC_ID" || true
  fi
  aws ec2 release-address --region "$REGION" --allocation-id "$PUB_EIP_ALLOC_ID" || true
  echo "Released public EC2 EIP: $PUB_EIP_ALLOC_ID"
fi

# ---- Delete NAT Gateway (then release its EIP) ----
if [[ -n "${NAT_GW_ID:-}" ]]; then
  aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT_GW_ID" || true
  aws ec2 wait nat-gateway-deleted --region "$REGION" --nat-gateway-ids "$NAT_GW_ID" || true
  echo "NAT Gateway deleted: $NAT_GW_ID"
fi
if [[ -n "${NAT_EIP_ALLOC_ID:-}" ]]; then
  aws ec2 release-address --region "$REGION" --allocation-id "$NAT_EIP_ALLOC_ID" || true
  echo "Released NAT EIP: $NAT_EIP_ALLOC_ID"
fi

# ---- Disassociate and delete Route Tables ----
if [[ -n "${PUB_RTB_ID:-}" ]]; then
  ASSOCS=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PUB_RTB_ID" \
    --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text || true)
  for a in $ASSOCS; do
    aws ec2 disassociate-route-table --region "$REGION" --association-id "$a" || true
  done
  aws ec2 delete-route-table --region "$REGION" --route-table-id "$PUB_RTB_ID" || true
  echo "Deleted public RTB: $PUB_RTB_ID"
fi

if [[ -n "${PRIV_RTB_ID:-}" ]]; then
  ASSOCS=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$PRIV_RTB_ID" \
    --query "RouteTables[0].Associations[?Main==\`false\`].RouteTableAssociationId" --output text || true)
  for a in $ASSOCS; do
    aws ec2 disassociate-route-table --region "$REGION" --association-id "$a" || true
  done
  aws ec2 delete-route-table --region "$REGION" --route-table-id "$PRIV_RTB_ID" || true
  echo "Deleted private RTB: $PRIV_RTB_ID"
fi

# ---- Detach & delete Internet Gateway ----
if [[ -n "${IGW_ID:-}" && -n "${VPC_ID:-}" ]]; then
  aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" || true
  aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" || true
  echo "Deleted IGW: $IGW_ID"
fi

# ---- Delete Subnets ----
if [[ -n "${PRIV_SUBNET_ID:-}" ]]; then
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$PRIV_SUBNET_ID" || true
  echo "Deleted private subnet: $PRIV_SUBNET_ID"
fi
if [[ -n "${PUB_SUBNET_ID:-}" ]]; then
  aws ec2 delete-subnet --region "$REGION" --subnet-id "$PUB_SUBNET_ID" || true
  echo "Deleted public subnet: $PUB_SUBNET_ID"
fi

# ---- Delete Security Groups ----
if [[ -n "${PRIVATE_SG_ID:-}" ]]; then
  aws ec2 delete-security-group --region "$REGION" --group-id "$PRIVATE_SG_ID" || true
  echo "Deleted private SG: $PRIVATE_SG_ID"
fi
if [[ -n "${PUBLIC_SG_ID:-}" ]]; then
  aws ec2 delete-security-group --region "$REGION" --group-id "$PUBLIC_SG_ID" || true
  echo "Deleted public SG: $PUBLIC_SG_ID"
fi

# ---- Delete VPC ----
if [[ -n "${VPC_ID:-}" ]]; then
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" || true
  echo "Deleted VPC: $VPC_ID"
fi

# ---- Delete key pair (AWS + local file) ----
if [[ -n "${KEY_NAME:-}" ]]; then
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" || true
  echo "Deleted key pair: $KEY_NAME"
fi
if [[ -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]]; then
  rm -f "$KEY_FILE"
  echo "Removed local key file: $KEY_FILE"
fi

echo "✅ Teardown complete. You can remove $STATE_FILE if you like."
