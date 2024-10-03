#!/bin/bash

# Global output directory
OUTPUT_DIR="./out"

# Function to check the operating system and get the correct date based on a user-defined duration
get_older_than_date() {
    local duration=$1
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo $(date --date="$duration ago" +"%Y-%m-%d")
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo $(date -v -"$duration" +"%Y-%m-%d")
    else
        echo "Unsupported OS: $OSTYPE"
        exit 1
    fi
}

# Ensure output directory exists
prepare_output_dir() {
    mkdir -p "$OUTPUT_DIR"
}

# Function to list AMIs not used
list_amis() {
  local duration=$1
  local region=$2
  FROM_DATE=$(get_older_than_date $duration)

  local amis_candidates_file="$OUTPUT_DIR/amis_candidates_$region.txt"

  comm -23 <(cat \
    <(aws ec2 describe-images --region $region --owners self --query "Images[?CreationDate<'$FROM_DATE' && !not_null(LastLaunchedTime)].ImageId" --output text | tr '\t' '\n' | sort | uniq) \
    <(aws ec2 describe-images --region $region --owners self --query "Images[?LastLaunchedTime <'$FROM_DATE'].ImageId" --output text | tr '\t' '\n' | sort | uniq) \
    | sort | uniq) \
    <(aws ec2 describe-instances --region $region --query 'Reservations[*].Instances[*].ImageId' --output text | sort | uniq) \
    | sort | uniq > "$amis_candidates_file"

  if [ -s "$amis_candidates_file" ]; then
    get_amis_price "$amis_candidates_file" "$region"
  else
    rm -f "$amis_candidates_file"
  fi
}

# Function to get total size of amis
get_amis_price() {
  TOTAL_SIZE=0
  AMI_FILE="$1"
  local region=$2

  # Iterate over each AMI ID in the input file
  while IFS= read -r ami_id; do
    # Get the size of the AMI using AWS CLI by fetching the associated snapshot sizes
    snapshot_size=$(aws ec2 describe-images --region "$region" --image-ids "$ami_id" --query 'Images[0].BlockDeviceMappings[*].Ebs.VolumeSize' --output text | awk '{sum+=$1} END {print sum}')

    # Check if size was retrieved successfully
    if [[ "$snapshot_size" =~ ^[0-9]+$ ]]; then
      # Add the size to the total
      TOTAL_SIZE=$((TOTAL_SIZE + snapshot_size))
    else
      echo "Could not retrieve size for AMI ID: $ami_id"
    fi
  done < "$AMI_FILE"

  # Output the total size and estimated cost
  echo "Total size of AMIs: $TOTAL_SIZE GB"
  COST=$(echo "$TOTAL_SIZE * 0.053" | bc)
  echo "This costs approximately $COST € for storage."
}

# Function to list snapshots
list_snapshots() {
  local duration=$1
  local region=$2
  FROM_DATE=$(get_older_than_date $duration)
  
  # Prepare output filenames
  local volumes_file="$OUTPUT_DIR/volumes_$region.txt"
  local snapshots_candidates_file="$OUTPUT_DIR/snapshots_candidates_$region.txt"

  comm -23 \
    <(aws ec2 describe-snapshots --region $region --owner-ids self \
    --query "Snapshots[?StartTime<='$FROM_DATE' && !starts_with(Description, 'Created by CreateImage') && !starts_with(Description, 'This snapshot is created by the AWS Backup service')].VolumeId" \
    --output text | tr '\t' '\n' | sort | uniq) \
    <(aws ec2 describe-volumes --region $region --query 'Volumes[*].VolumeId' --output text | tr '\t' '\n' | sort | uniq) \
    > "$volumes_file"

  aws ec2 describe-snapshots --region $region \
    --query "Snapshots[*].SnapshotId" --filters Name=volume-id,Values="$(awk '{print $1}' $volumes_file | paste -s -d, -)" \
    --output text | tr '\t' '\n' | sort | uniq > "$snapshots_candidates_file"

  rm -f "$volumes_file"

  if [ -s "$snapshots_candidates_file" ]; then
    get_snapshots_price "$snapshots_candidates_file" "$region"
  else
    rm -f "$snapshots_candidates_file"
  fi
}

# Function to get total price of snapshots
get_snapshots_price() {
  TOTAL_SIZE=0
  SNAPSHOT_FILE="$1"
  local region=$2

  while IFS= read -r snapshot_id; do
    size=$(aws ec2 describe-snapshots --region $region --snapshot-ids "$snapshot_id" --query 'Snapshots[0].VolumeSize' --output text)
    
    if [[ "$size" =~ ^[0-9]+$ ]]; then
      TOTAL_SIZE=$((TOTAL_SIZE + size))
    else
      echo "Could not retrieve size for snapshot ID: $snapshot_id"
    fi
  done < "$SNAPSHOT_FILE"

  echo "Total size of snapshots: $TOTAL_SIZE GB"
  COST=$(echo "$TOTAL_SIZE * 0.053" | bc)
  echo "This costs approximately $COST € for storage."
}

# Function to delete snapshots
delete_snapshots() {
  local snapshot_id="$1"
  local region="$2"
  aws ec2 delete-snapshot --region "$region" --snapshot-id "$snapshot_id"
}

# Function to delete snapshots from file input
delete_snapshots_from_file() {
  SNAPSHOT_FILE="$1"
  local region="$2"
  COUNT=0

  # Iterate over each snapshot ID in the file
  while IFS= read -r snapshot_id; do
    delete_snapshots $snapshot_id $region
    let "COUNT++"
  done < "$SNAPSHOT_FILE"

  echo "Deleted $COUNT snapshots in region: $region."
}

# Function to delete amis from file input
delete_amis_from_file() {
  SNAPSHOT_FILE="$1"
  local region="$2"
  COUNT=0

  # Iterate over each snapshot ID in the file
  while IFS= read -r ami_id; do
    local snapshot_id=$(aws ec2 describe-images --region "$region" --image-ids $ami_id)
    aws ec2 deregister-image --region "$region" --image-id "$ami_id"
    if [[ -z "$snapshot_id" ]]; then
      echo "[$region] Deleting associated snapshot to ami $ami_id."
      delete_snapshots $snapshot_id $region
    fi
    let "COUNT++"
  done < "$SNAPSHOT_FILE"

  echo "Deleted $COUNT amis in region: $region."
}

# Function to run the list command in all regions
list_amis_all_regions() {
  local duration=$1
  regions=$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text)

  for region in $regions; do
    echo "Listing amis in region: $region"
    list_amis "$duration" "$region"
  done
}

# Function to run the list command in all regions
list_snapshots_all_regions() {
  local duration=$1
  regions=$(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text)

  for region in $regions; do
    echo "Listing snapshots in region: $region"
    list_snapshots "$duration" "$region"
  done
}

# Main logic for handling parameters
COMMAND=""
SUBCOMMAND=""
REGION=""
DURATION=""
ALL_REGION=false

# Parse parameters
while [[ "$#" -gt 0 ]]; do
  case $1 in
    snapshots) COMMAND="snapshots"; shift ;;
    amis) COMMAND="amis"; shift ;;
    list) SUBCOMMAND="list"; shift ;;
    delete) SUBCOMMAND="delete"; shift ;;
    --region) REGION="$2"; shift; shift ;;
    --all-region) ALL_REGION=true; shift ;;
    *) DURATION="$1"; shift ;;
  esac
done

# Check if the output directory exists
prepare_output_dir

# Execute commands based on parameters
if [[ "$COMMAND" == "snapshots" && "$SUBCOMMAND" == "list" ]]; then
  if [[ -z "$DURATION" ]]; then
    echo "Error: Missing required 'older-than' parameter."
    echo "Usage: $0 snapshots list <older-than> [--region REGION | --all-region]"
    exit 1
  fi
  if $ALL_REGION; then
    list_snapshots_all_regions "$DURATION"
  else
    if [[ -z "$REGION" ]]; then
      echo "Error: Missing required '--region' parameter."
      exit 1
    fi
    list_snapshots "$DURATION" "$REGION"
  fi
elif [[ "$COMMAND" == "snapshots" && "$SUBCOMMAND" == "delete" ]]; then
  if  [[ -z "$REGION" ]]; then
    echo "Error: Missing required '--region' parameter."
    exit 1    
  fi

  delete_snapshots_from_file "out/snapshots_candidates_$REGION.txt" "$REGION"

elif [[ "$COMMAND" == "amis" && "$SUBCOMMAND" == "list" ]]; then
  if [[ -z "$DURATION" ]]; then
    echo "Error: Missing required 'older-than' parameter."
    echo "Usage: $0 amis list <older-than> [--region REGION | --all-region]"
    exit 1
  fi
  if $ALL_REGION; then
    list_amis_all_regions "$DURATION"
  else
    if [[ -z "$REGION" ]]; then
      echo "Error: Missing required '--region' parameter."
      exit 1
    fi
    list_amis "$DURATION" "$REGION"
  fi
elif [[ "$COMMAND" == "amis" && "$SUBCOMMAND" == "delete" ]]; then
  if  [[ -z "$REGION" ]]; then
    echo "Error: Missing required '--region' parameter."
    exit 1    
  fi
  delete_amis_from_file "out/amis_candidates_$REGION.txt" "$REGION"

else
  echo "Usage: $0 {snapshots|amis} {list|delete} ...args [--region REGION | --all-region]"
  exit 1
fi
