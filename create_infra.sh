#!/usr/bin/env bash
set -euo pipefail

# ========= Config (edit if you like) =========
REGION="us-west-1"
AZ="${REGION}a"
VPC_CIDR="10.0.0.0/16"
PUB_CIDR="10.0.1.0/24"
PRIV_CIDR="10.0.2.0/24"
INSTANCE_TYPE="t3.micro"                 # small and cheap
VPC_NAME="app-vpc"
STATE_FILE="./aws_vpc_stack_ids.env"
STACK_ID="$(date +%Y%m%d%H%M%S)"
KEY_NAME="stack-${STACK_ID}-key"
KEY_FILE="./${KEY_NAME}.pem"
PUB_SG_NAME="public-ssh-sg"
PRIV_SG_NAME="private-ssh-sg"
# ============================================

echo "Using REGION = $REGION ; STACK_ID = $STACK_ID"
: > "$STATE_FILE"  # truncate state file

# Helper to append to state file
save() { echo "$1=\"$2\"" >> "$STATE_FILE"; }

# ---- VPC ----
VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=StackId,Value=$STACK_ID}]" \
  --query "Vpc.VpcId" --output text)
echo "VPC: $VPC_ID"
save VPC_ID "$VPC_ID"; save REGION "$REGION"; save STACK_ID "$STACK_ID"

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames

# ---- Subnets ----
PUB_SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
  --cidr-block "$PUB_CIDR" --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=public}]" \
  --query "Subnet.SubnetId" --output text)
echo "Public Subnet: $PUB_SUBNET_ID"
save PUB_SUBNET_ID "$PUB_SUBNET_ID"

aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$PUB_SUBNET_ID" --map-public-ip-on-launch

PRIV_SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
  --cidr-block "$PRIV_CIDR" --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=private}]" \
  --query "Subnet.SubnetId" --output text)
echo "Private Subnet: $PRIV_SUBNET_ID"
save PRIV_SUBNET_ID "$PRIV_SUBNET_ID"

# ---- Internet Gateway + Public RT ----
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=public-igw},{Key=StackId,Value=$STACK_ID}]" \
  --query "InternetGateway.InternetGatewayId" --output text)
echo "IGW: $IGW_ID"
save IGW_ID "$IGW_ID"

aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

PUB_RTB_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=public-rtb},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=public}]" \
  --query "RouteTable.RouteTableId" --output text)
echo "Public RTB: $PUB_RTB_ID"
save PUB_RTB_ID "$PUB_RTB_ID"

aws ec2 create-route --region "$REGION" --route-table-id "$PUB_RTB_ID" \
  --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null

aws ec2 associate-route-table --region "$REGION" --route-table-id "$PUB_RTB_ID" --subnet-id "$PUB_SUBNET_ID" >/dev/null

# ---- NAT Gateway + Private RT ----
# Elastic IP for NAT
NAT_EIP_ALLOC_ID=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
  --query "AllocationId" --output text)
aws ec2 create-tags --region "$REGION" --resources "$NAT_EIP_ALLOC_ID" \
  --tags Key=Name,Value=public-nat-eip Key=StackId,Value="$STACK_ID" >/dev/null
echo "NAT EIP Allocation: $NAT_EIP_ALLOC_ID"
save NAT_EIP_ALLOC_ID "$NAT_EIP_ALLOC_ID"

NAT_GW_ID=$(aws ec2 create-nat-gateway --region "$REGION" \
  --subnet-id "$PUB_SUBNET_ID" --allocation-id "$NAT_EIP_ALLOC_ID" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=public-natgw},{Key=StackId,Value=$STACK_ID}]" \
  --query "NatGateway.NatGatewayId" --output text)
echo "NAT GW: $NAT_GW_ID (creating...)"
save NAT_GW_ID "$NAT_GW_ID"

aws ec2 wait nat-gateway-available --region "$REGION" --nat-gateway-ids "$NAT_GW_ID"
echo "NAT GW is available."

PRIV_RTB_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=private-rtb},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=private}]" \
  --query "RouteTable.RouteTableId" --output text)
echo "Private RTB: $PRIV_RTB_ID"
save PRIV_RTB_ID "$PRIV_RTB_ID"

aws ec2 create-route --region "$REGION" --route-table-id "$PRIV_RTB_ID" \
  --destination-cidr-block "0.0.0.0/0" --nat-gateway-id "$NAT_GW_ID" >/dev/null

aws ec2 associate-route-table --region "$REGION" --route-table-id "$PRIV_RTB_ID" --subnet-id "$PRIV_SUBNET_ID" >/dev/null

# ---- Security Groups ----
# Public SG: SSH from anywhere (tighten later to your IP if desired)
PUBLIC_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$PUB_SG_NAME" --description "Allow SSH" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PUB_SG_NAME},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=public}]" \
  --query "GroupId" --output text)
echo "Public SG: $PUBLIC_SG_ID"
save PUBLIC_SG_ID "$PUBLIC_SG_ID"

aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$PUBLIC_SG_ID" \
  --ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description="SSH"}]' >/dev/null

# Private SG: SSH only from instances in the Public SG (bastion pattern)
PRIVATE_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$PRIV_SG_NAME" --description "Allow SSH from public SG" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$PRIV_SG_NAME},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=private}]" \
  --query "GroupId" --output text)
echo "Private SG: $PRIVATE_SG_ID"
save PRIVATE_SG_ID "$PRIVATE_SG_ID"

aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$PRIVATE_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,UserIdGroupPairs=[{GroupId=$PUBLIC_SG_ID,Description=SSH-from-public-sg}]" >/dev/null

# ---- Key Pair (saved locally) ----
if [[ -e "$KEY_FILE" ]]; then
  echo "Key file $KEY_FILE already exists; refusing to overwrite." >&2
  exit 1
fi
aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
  --key-type rsa --key-format pem \
  --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$KEY_NAME},{Key=StackId,Value=$STACK_ID}]" \
  --query "KeyMaterial" --output text > "$KEY_FILE"
chmod 600 "$KEY_FILE"
echo "Created key pair: $KEY_NAME  -> $KEY_FILE"
save KEY_NAME "$KEY_NAME"; save KEY_FILE "$KEY_FILE"

# ---- Find Ubuntu AMI (latest 24.04 LTS) ----
AMI_ID=$(aws ec2 describe-images \
  --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  echo "I don’t know the Ubuntu AMI ID; describe-images returned empty. Check your region or filters." >&2
  exit 1
fi
echo "Ubuntu 24.04 AMI: $AMI_ID"

# ---- EC2 Instances ----
# Public instance
PUB_INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --subnet-id "$PUB_SUBNET_ID" --security-group-ids "$PUBLIC_SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=public-ec2},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=public}]" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query "Instances[0].InstanceId" --output text)
echo "Public EC2: $PUB_INSTANCE_ID"
save PUB_INSTANCE_ID "$PUB_INSTANCE_ID"

# Private instance
PRIV_INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --subnet-id "$PRIV_SUBNET_ID" --security-group-ids "$PRIVATE_SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=private-ec2},{Key=StackId,Value=$STACK_ID},{Key=Role,Value=private}]" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":8,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query "Instances[0].InstanceId" --output text)
echo "Private EC2: $PRIV_INSTANCE_ID"
save PRIV_INSTANCE_ID "$PRIV_INSTANCE_ID"

# Wait until instances are running (so we can bind EIP and read IPs)
aws ec2 wait instance-running --region "$REGION" --instance-ids "$PUB_INSTANCE_ID" "$PRIV_INSTANCE_ID"

# ---- Allocate & Associate an Elastic IP to the PUBLIC instance ----
PUB_EIP_ALLOC_ID=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
  --query "AllocationId" --output text)
aws ec2 create-tags --region "$REGION" --resources "$PUB_EIP_ALLOC_ID" \
  --tags Key=Name,Value=public-ec2-eip Key=StackId,Value="$STACK_ID" >/dev/null
PUB_EIP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$PUB_EIP_ALLOC_ID" --query "Addresses[0].PublicIp" --output text)
ASSOC_ID=$(aws ec2 associate-address --region "$REGION" \
  --instance-id "$PUB_INSTANCE_ID" --allocation-id "$PUB_EIP_ALLOC_ID" \
  --query "AssociationId" --output text)
echo "Elastic IP for public EC2: $PUB_EIP (Association: $ASSOC_ID)"
save PUB_EIP_ALLOC_ID "$PUB_EIP_ALLOC_ID"; save PUB_EIP "$PUB_EIP"; save PUB_EIP_ASSOC_ID "$ASSOC_ID"

# ---- Fetch instance IPs (for convenience) ----
# Public instance's private IP (handy sometimes)
PUB_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$PUB_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
save PUB_PRIVATE_IP "$PUB_PRIVATE_IP"

# Private instance's private IP (the one you'll SSH to from the public host)
PRIV_PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$PRIV_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
echo "Private EC2 private IP: $PRIV_PRIVATE_IP"
save PRIV_PRIVATE_IP "$PRIV_PRIVATE_IP"

# ---- Final Summary ----
cat <<EOF

✅ Done. StackId: $STACK_ID
Saved state: $STATE_FILE

Created:
- VPC               $VPC_ID  (Name=$VPC_NAME)
- Subnets           public=$PUB_SUBNET_ID ($PUB_CIDR) ; private=$PRIV_SUBNET_ID ($PRIV_CIDR)
- IGW               $IGW_ID  (attached)
- RTBs              public=$PUB_RTB_ID (0.0.0.0/0->IGW) ; private=$PRIV_RTB_ID (0.0.0.0/0->NAT)
- NAT GW            $NAT_GW_ID  (EIP Alloc=$NAT_EIP_ALLOC_ID)
- SGs               public=$PUBLIC_SG_ID ; private=$PRIVATE_SG_ID (SSH only from public SG)
- Key pair          $KEY_NAME  (file: $KEY_FILE)
- EC2 instances     public=$PUB_INSTANCE_ID ; private=$PRIV_INSTANCE_ID
- Public Elastic IP $PUB_EIP (allocated=$PUB_EIP_ALLOC_ID and associated to $PUB_INSTANCE_ID)
- Private IP (priv) $PRIV_PRIVATE_IP

SSH:
    ssh -i "$KEY_FILE" ubuntu@$PUB_EIP
   
   Once inside, copy "$KEY_FILE" into the instance and give it the proper permissions.
   Then run:
    ssh -i "$KEY_FILE" ubuntu@$PRIV_PRIVATE_IP



Note: both instances use the same key pair ($KEY_NAME). 
Disclaimer: Copying the key pair file isn't the most secure. Proceed with caution.
Reminder: NAT Gateways and EIPs bill while active.
EOF
