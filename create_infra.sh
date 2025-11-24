#!/usr/bin/env bash
set -euo pipefail

# ============================================
#  AWS OpenVPN Cluster Setup (Class Project)
# ============================================
# Region: us-east-1
# AMI: OpenVPN Access Server (BYOL)
# Zones: us-east-1a, us-east-1b, us-east-1c
# Networking: 3 Public Subnets, IGW, 3 Elastic IPs
# Security: Custom Ports (943, 945, 1194) + Standard
# ============================================

# Config
REGION="us-east-1"
VPC_CIDR="10.0.0.0/16"
VPC_NAME="vpn-project-vpc"
INSTANCE_TYPE="t3.micro"
AMI_ID="ami-06e5a963b2dadea6f" # OpenVPN Access Server Community Image
STACK_ID="$(date +%Y%m%d%H%M%S)"
KEY_NAME="vpn-project-${STACK_ID}-key"
KEY_FILE="./${KEY_NAME}.pem"
SG_NAME="vpn-node-sg"
STATE_FILE="./vpn_infrastructure.env"

echo "🚀 Starting Deployment in $REGION with Stack ID: $STACK_ID"
echo "⚠️  Ensure you have subscribed to the OpenVPN AMI in Marketplace first!"
: > "$STATE_FILE"

save() { echo "$1=\"$2\"" >> "$STATE_FILE"; }

# 1. Create VPC
echo "--- Creating VPC ---"
VPC_ID=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=StackId,Value=$STACK_ID}]" \
  --query "Vpc.VpcId" --output text)
echo "✅ VPC Created: $VPC_ID"
save VPC_ID "$VPC_ID"

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames

# 2. Internet Gateway
echo "--- Creating Internet Gateway ---"
IGW_ID=$(aws ec2 create-internet-gateway --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=vpn-igw},{Key=StackId,Value=$STACK_ID}]" \
  --query "InternetGateway.InternetGatewayId" --output text)
aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "✅ IGW Created & Attached: $IGW_ID"

# 3. Route Table (Public)
echo "--- Creating Public Route Table ---"
RTB_ID=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=vpn-public-rtb},{Key=StackId,Value=$STACK_ID}]" \
  --query "RouteTable.RouteTableId" --output text)
aws ec2 create-route --region "$REGION" --route-table-id "$RTB_ID" \
  --destination-cidr-block "0.0.0.0/0" --gateway-id "$IGW_ID" >/dev/null
echo "✅ Route Table Created: $RTB_ID"

# 4. Security Group
echo "--- Creating Security Group ---"
SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name "$SG_NAME" --description "OpenVPN Security Group" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=StackId,Value=$STACK_ID}]" \
  --query "GroupId" --output text)
echo "✅ Security Group Created: $SG_ID"

# Inbound Rules
# TCP: 22 (SSH), 80 (HTTP), 443 (HTTPS), 943 (OpenVPN Web UI), 945 (Cluster)
# UDP: 1194 (OpenVPN Tunnel)
echo "Configuring Firewall Rules..."
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
  --ip-permissions \
  '[
    {"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 80, "ToPort": 80, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 443, "ToPort": 443, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 943, "ToPort": 943, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "tcp", "FromPort": 945, "ToPort": 945, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]},
    {"IpProtocol": "udp", "FromPort": 1194, "ToPort": 1194, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}
  ]' >/dev/null

# 5. Create Key Pair
echo "--- Creating Key Pair ---"
if [[ -e "$KEY_FILE" ]]; then rm "$KEY_FILE"; fi
aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
  --key-type rsa --key-format pem \
  --query "KeyMaterial" --output text > "$KEY_FILE"
chmod 600 "$KEY_FILE"
echo "✅ Key Pair Saved: $KEY_FILE"

# 6. Loop to Create 3 Nodes (Subnet -> Instance -> EIP -> Config)
AZS=("us-east-1a" "us-east-1b" "us-east-1c")
CIDRS=("10.0.1.0/24" "10.0.2.0/24" "10.0.3.0/24")

for i in {0..2}; do
  AZ="${AZS[$i]}"
  CIDR="${CIDRS[$i]}"
  NODE_NUM=$((i+1))
  
  echo "------------------------------------------------"
  echo "🚀 Launching Node $NODE_NUM in $AZ"
  echo "------------------------------------------------"

  # Create Subnet
  SUBNET_ID=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR" --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=vpn-subnet-$AZ},{Key=StackId,Value=$STACK_ID}]" \
    --query "Subnet.SubnetId" --output text)
  echo "   - Subnet Created: $SUBNET_ID"
  
  # Enable Public IP on Launch (Optional since we use EIP, but good practice for public subnets)
  aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

  # Associate Route Table
  aws ec2 associate-route-table --region "$REGION" --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID" >/dev/null

  # Launch Instance
  INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
    --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=vpn-node-$AZ},{Key=StackId,Value=$STACK_ID}]" \
    --query "Instances[0].InstanceId" --output text)
  echo "   - Instance Launched: $INSTANCE_ID"
  save "NODE_${NODE_NUM}_ID" "$INSTANCE_ID"

  # Disable Source/Dest Check
  aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$INSTANCE_ID" --no-source-dest-check
  echo "   - Source/Dest Check: Disabled"

  # Create & Associate Elastic IP
  ALLOC_ID=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=vpn-eip-$AZ},{Key=StackId,Value=$STACK_ID}]" \
    --query "AllocationId" --output text)
  
  # Wait for instance to be running before associating EIP
  echo "   - Waiting for instance to initialize..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
  
  ASSOC_ID=$(aws ec2 associate-address --region "$REGION" \
    --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" \
    --query "AssociationId" --output text)
  
  PUBLIC_IP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$ALLOC_ID" --query "Addresses[0].PublicIp" --output text)
  echo "   - Elastic IP Attached: $PUBLIC_IP"
  save "NODE_${NODE_NUM}_IP" "$PUBLIC_IP"
done

echo "================================================"
echo "🎉 DEPLOYMENT COMPLETE"
echo "================================================"
echo "SSH Key: $KEY_FILE"
echo "To connect (Username is usually 'openvpnas' or 'root' for this AMI):"
echo "ssh -i $KEY_FILE openvpnas@<Public-IP>"
echo "Access the Web UI at: https://<Public-IP>:943/admin"
echo "================================================"