#!/bin/bash
set -euo pipefail

# Script to manually cleanup gitops-vms namespace on the non-primary cluster
# This script will:
# 1. Determine the non-primary cluster (discovered from DR policy; override with PRIMARY_CLUSTER/SECONDARY_CLUSTER env if needed)
# 2. Render the helm template with the same chart version and values
# 3. Extract resource kinds and names
# 4. Delete them from the gitops-vms namespace

# Configuration
HELM_CHART_URL="https://github.com/validatedpatterns/helm-charts/releases/download/main/edge-gitops-vms-0.3.3.tgz"
WORK_DIR="/tmp/edge-gitops-vms-cleanup"
VM_NAMESPACE="gitops-vms"
DRPC_NAMESPACE="openshift-dr-ops"
DRPC_NAME="gitops-vm-protection"
PLACEMENT_NAME="gitops-vm-protection-placement-1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Initialize variables
PRIMARY_CLUSTER=""
NON_PRIMARY_CLUSTER=""

# Create working directory
mkdir -p "$WORK_DIR"

# Function to determine current primary cluster from DRPC
determine_primary_cluster() {
  echo "Determining current primary cluster from DRPC..."
  
  # Check if DRPC exists
  if ! oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}  ⚠️  Warning: DRPC $DRPC_NAME not found in namespace $DRPC_NAMESPACE${NC}"
    echo "  Cannot determine primary cluster from DRPC"
    return 1
  fi
  
  # First, check PlacementDecision - this is the most reliable way to determine current primary
  # The PlacementDecision shows which cluster is currently selected by the Placement
  local placement_cluster=$(oc get placementdecision -n "$DRPC_NAMESPACE" \
    -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || echo "")
  
  if [[ -n "$placement_cluster" ]]; then
    PRIMARY_CLUSTER="$placement_cluster"
    echo "  ✅ Current primary cluster from PlacementDecision: $PRIMARY_CLUSTER"
    echo "    (This is the cluster where VMs are currently deployed)"
    return 0
  fi
  
  # Fallback: Get preferred cluster from DRPC spec
  local preferred_cluster=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.spec.preferredCluster}' 2>/dev/null || echo "")
  
  if [[ -n "$preferred_cluster" ]]; then
    PRIMARY_CLUSTER="$preferred_cluster"
    echo "  ⚠️  Using preferred cluster from DRPC spec: $PRIMARY_CLUSTER"
    echo "    (PlacementDecision not available - this may not reflect current state after failover)"
    return 0
  fi
  
  echo -e "${YELLOW}  ⚠️  Warning: Could not determine primary cluster from DRPC${NC}"
  echo "    - PlacementDecision not found for $PLACEMENT_NAME"
  echo "    - DRPC preferredCluster not found"
  return 1
}

# Function to determine non-primary cluster
determine_non_primary_cluster() {
  echo "Determining non-primary cluster for cleanup..."
  
  # Get all clusters from DRPolicy
  local dr_policy_name=$(oc get drplacementcontrol "$DRPC_NAME" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.spec.drPolicyRef.name}' 2>/dev/null || echo "")
  
  if [[ -z "$dr_policy_name" ]]; then
    echo -e "${YELLOW}  ⚠️  Warning: Could not get DRPolicy name from DRPC${NC}"
    return 1
  fi
  
  # Get clusters from DRPolicy
  local dr_clusters=$(oc get drpolicy "$dr_policy_name" \
    -o jsonpath='{.spec.drClusters[*]}' 2>/dev/null || echo "")
  
  if [[ -z "$dr_clusters" ]]; then
    echo -e "${YELLOW}  ⚠️  Warning: Could not get DR clusters from DRPolicy${NC}"
    return 1
  fi
  
  echo "  DR clusters in policy: $dr_clusters"
  echo "  Current primary cluster: $PRIMARY_CLUSTER"
  
  # Find the non-primary cluster
  NON_PRIMARY_CLUSTER=""
  for cluster in $dr_clusters; do
    if [[ "$cluster" != "$PRIMARY_CLUSTER" ]]; then
      NON_PRIMARY_CLUSTER="$cluster"
      break
    fi
  done
  
  if [[ -z "$NON_PRIMARY_CLUSTER" ]]; then
    echo -e "${RED}  ❌ Error: Could not determine non-primary cluster${NC}"
    echo "  Primary cluster: $PRIMARY_CLUSTER"
    echo "  DR clusters: $dr_clusters"
    return 1
  fi
  
  echo "  ✅ Non-primary cluster determined: $NON_PRIMARY_CLUSTER"
  return 0
}

# Main execution starts here
echo "=========================================="
echo "GitOps VMs Cleanup Script"
echo "=========================================="
echo "DRPC: $DRPC_NAME (namespace: $DRPC_NAMESPACE)"
echo ""

# Determine primary and non-primary clusters
if ! determine_primary_cluster; then
  echo -e "${YELLOW}  ⚠️  Warning: Could not determine primary cluster from DRPC${NC}"
  echo "  You can specify the non-primary cluster as an argument: $0 <cluster-name>"
  if [[ -n "${1:-}" ]]; then
    NON_PRIMARY_CLUSTER="$1"
    echo "  Using provided cluster: $NON_PRIMARY_CLUSTER"
  else
    echo -e "${RED}  ❌ Error: Cannot proceed without determining clusters${NC}"
    exit 1
  fi
else
  if ! determine_non_primary_cluster; then
    echo -e "${YELLOW}  ⚠️  Warning: Could not determine non-primary cluster${NC}"
    if [[ -n "${1:-}" ]]; then
      NON_PRIMARY_CLUSTER="$1"
      echo "  Using provided cluster: $NON_PRIMARY_CLUSTER"
    else
      echo -e "${RED}  ❌ Error: Cannot proceed without determining non-primary cluster${NC}"
      exit 1
    fi
  fi
fi

echo ""
echo "=========================================="
echo "Cleanup Configuration"
echo "=========================================="
echo "Primary cluster: ${PRIMARY_CLUSTER:-<not determined>}"
echo "Non-primary cluster (target for cleanup): $NON_PRIMARY_CLUSTER"
echo "Namespace: $VM_NAMESPACE"
echo ""

# Function to get kubeconfig for a managed cluster
get_cluster_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$WORK_DIR/${cluster}-kubeconfig.yaml"
  
  echo "Getting kubeconfig for cluster: $cluster"
  
  # Try to get kubeconfig from secret
  local kubeconfig_secret=$(oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1)
  
  if [[ -z "$kubeconfig_secret" ]]; then
    echo -e "${RED}  ❌ No kubeconfig secret found for cluster $cluster${NC}"
    return 1
  fi
  
  echo "  Found kubeconfig secret: $kubeconfig_secret"
  
  # Try to get the kubeconfig data
  local kubeconfig_data=""
  
  # First try to get the 'kubeconfig' field
  kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  # If that fails, try the 'raw-kubeconfig' field
  if [[ -z "$kubeconfig_data" ]]; then
    kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  
  if [[ -z "$kubeconfig_data" ]]; then
    echo -e "${RED}  ❌ Could not extract kubeconfig data for cluster $cluster${NC}"
    return 1
  fi
  
  # Write the kubeconfig to file
  echo "$kubeconfig_data" > "$kubeconfig_path"
  
  # Validate kubeconfig
  if oc --kubeconfig="$kubeconfig_path" get nodes --request-timeout=5s &>/dev/null; then
    echo -e "${GREEN}  ✅ Kubeconfig downloaded and validated for $cluster${NC}"
    export KUBECONFIG="$kubeconfig_path"
    return 0
  else
    echo -e "${RED}  ❌ Kubeconfig for $cluster is invalid or cluster is unreachable${NC}"
    return 1
  fi
}

# Function to render helm template
render_helm_template() {
  echo ""
  echo "Step 1: Rendering helm template..."
  echo "  Chart URL: $HELM_CHART_URL"
  
  # Get the script directory and project root
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  
  # Get the values file path
  # Try to find it in the chart directory first
  VALUES_FILE=""
  if [[ -f "$PROJECT_ROOT/charts/hub/rdr/files/values-egv-dr.yaml" ]]; then
    VALUES_FILE="$PROJECT_ROOT/charts/hub/rdr/files/values-egv-dr.yaml"
    echo "  Found values file: $VALUES_FILE"
  elif [[ -f "$PROJECT_ROOT/overrides/values-egv-dr.yaml" ]]; then
    VALUES_FILE="$PROJECT_ROOT/overrides/values-egv-dr.yaml"
    echo "  Found values file: $VALUES_FILE"
  else
    echo -e "${YELLOW}  ⚠️  Warning: Could not find values-egv-dr.yaml${NC}"
    echo "  Looking in: $PROJECT_ROOT/charts/hub/rdr/files/ and $PROJECT_ROOT/overrides/"
    echo "  Will try to render without values file (may not match exactly)"
  fi
  
  # Set up helm cache/config in /tmp to avoid permission issues
  export HELM_CACHE_HOME="/tmp/.helm/cache"
  export HELM_CONFIG_HOME="/tmp/.helm/config"
  mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME"
  
  # Build helm template command
  local helm_cmd="helm template edge-gitops-vms \"$HELM_CHART_URL\""
  if [[ -n "$VALUES_FILE" && -f "$VALUES_FILE" ]]; then
    helm_cmd="$helm_cmd --values \"$VALUES_FILE\""
  fi
  
  # Render helm template (run from /tmp to avoid permission issues)
  cd /tmp
  if eval "$helm_cmd" > "$WORK_DIR/helm-output.yaml" 2>&1; then
    echo -e "${GREEN}  ✅ Helm template rendered successfully${NC}"
  else
    echo -e "${RED}  ❌ Error: Failed to render helm template${NC}"
    echo "  Attempting to download chart first..."
    
    # Try downloading the chart first
    if curl -L -o "$WORK_DIR/edge-gitops-vms.tgz" "$HELM_CHART_URL" 2>/dev/null; then
      echo "  ✅ Chart downloaded successfully"
      if [[ -n "$VALUES_FILE" && -f "$VALUES_FILE" ]]; then
        if helm template edge-gitops-vms "$WORK_DIR/edge-gitops-vms.tgz" --values "$VALUES_FILE" > "$WORK_DIR/helm-output.yaml" 2>&1; then
          echo -e "${GREEN}  ✅ Helm template rendered successfully from local chart${NC}"
        else
          echo -e "${RED}  ❌ Error: Failed to render helm template from local chart${NC}"
          exit 1
        fi
      else
        if helm template edge-gitops-vms "$WORK_DIR/edge-gitops-vms.tgz" > "$WORK_DIR/helm-output.yaml" 2>&1; then
          echo -e "${GREEN}  ✅ Helm template rendered successfully from local chart${NC}"
        else
          echo -e "${RED}  ❌ Error: Failed to render helm template from local chart${NC}"
          exit 1
        fi
      fi
    else
      echo -e "${RED}  ❌ Error: Failed to download chart${NC}"
      exit 1
    fi
  fi
}

# Function to extract resources from helm output
extract_resources() {
  echo ""
  echo "Step 2: Extracting resources from helm template..."
  
  # Extract resources using yq or awk
  if command -v yq &>/dev/null; then
    # Use yq to extract resources
    yq eval 'select(.kind == "VirtualMachine" or .kind == "Service" or .kind == "Route" or .kind == "ExternalSecret")' \
      -d'*' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources.yaml" 2>/dev/null || true
  else
    # Use awk to extract resources
    awk '
      BEGIN { RS="---\n"; ORS="---\n" }
      /^kind: (VirtualMachine|Service|Route|ExternalSecret)$/ || /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ || /^kind: ExternalSecret$/ {
        print
        getline
        while (getline && !/^---$/) {
          print
        }
      }
    ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources.yaml" 2>/dev/null || true
  fi
  
  # Alternative: Use awk to extract resources with better parsing
  if [[ ! -s "$WORK_DIR/resources.yaml" ]]; then
    echo "  Using alternative method to extract resources..."
    awk '
      BEGIN { 
        RS="---"
        resource=""
      }
      /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ || /^kind: ExternalSecret$/ {
        resource=$0
        getline
        while (getline && !/^---$/) {
          resource=resource "\n" $0
        }
        if (resource != "") {
          print "---" resource
        }
      }
    ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources.yaml" 2>/dev/null || true
  fi
  
  # Extract resource list (kind|name|namespace)
  awk '
    BEGIN { 
      RS="---"
      kind=""
      name=""
      namespace=""
    }
    {
      if ($0 ~ /^kind: (VirtualMachine|Service|Route|ExternalSecret)$/ || $0 ~ /kind: VirtualMachine/ || $0 ~ /kind: Service/ || $0 ~ /kind: Route/ || $0 ~ /kind: ExternalSecret/) {
        split($0, lines, "\n")
        for (i=1; i<=length(lines); i++) {
          if (lines[i] ~ /^kind:/) {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            kind=parts[2]
          }
          if (lines[i] ~ /^[ \t]*name:/ && name == "") {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            name=parts[2]
          }
          if (lines[i] ~ /^[ \t]*namespace:/ && namespace == "") {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            namespace=parts[2]
          }
        }
        
        if (kind != "" && name != "") {
          print kind "|" name "|" namespace
        }
        kind=""
        name=""
        namespace=""
      }
    }
  ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-list.txt"
  
  # Count resources
  VM_COUNT=$(grep -c "^VirtualMachine|" "$WORK_DIR/resources-list.txt" 2>/dev/null | tr -d ' \n' || echo "0")
  SERVICE_COUNT=$(grep -c "^Service|" "$WORK_DIR/resources-list.txt" 2>/dev/null | tr -d ' \n' || echo "0")
  ROUTE_COUNT=$(grep -c "^Route|" "$WORK_DIR/resources-list.txt" 2>/dev/null | tr -d ' \n' || echo "0")
  EXTERNAL_SECRET_COUNT=$(grep -c "^ExternalSecret|" "$WORK_DIR/resources-list.txt" 2>/dev/null | tr -d ' \n' || echo "0")
  
  # Ensure counts are numeric
  VM_COUNT=${VM_COUNT:-0}
  SERVICE_COUNT=${SERVICE_COUNT:-0}
  ROUTE_COUNT=${ROUTE_COUNT:-0}
  EXTERNAL_SECRET_COUNT=${EXTERNAL_SECRET_COUNT:-0}
  
  echo "  Found resources in template:"
  echo "    - VirtualMachines: $VM_COUNT"
  echo "    - Services: $SERVICE_COUNT"
  echo "    - Routes: $ROUTE_COUNT"
  echo "    - ExternalSecrets: $EXTERNAL_SECRET_COUNT"
  
  if [[ $VM_COUNT -eq 0 && $SERVICE_COUNT -eq 0 && $ROUTE_COUNT -eq 0 && $EXTERNAL_SECRET_COUNT -eq 0 ]]; then
    echo -e "${YELLOW}  ⚠️  Warning: No resources found in helm template${NC}"
    echo "  This may indicate the template rendering failed or the values file doesn't match"
    return 1
  fi
  
  return 0
}

# Function to delete resources
delete_resources() {
  echo ""
  echo "Step 3: Deleting resources from namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER..."
  
  if [[ ! -s "$WORK_DIR/resources-list.txt" ]]; then
    echo -e "${RED}  ❌ No resources to delete (resources-list.txt is empty)${NC}"
    return 1
  fi
  
  local deleted_count=0
  local not_found_count=0
  local error_count=0
  
  # Delete each resource
  while IFS='|' read -r kind name namespace; do
    if [[ -z "$kind" || -z "$name" ]]; then
      continue
    fi
    
    # All resources should be in gitops-vms namespace
    local check_namespace="$VM_NAMESPACE"
    
    echo "  Deleting: $kind/$name in namespace $check_namespace"
    
    # Delete the resource
    if oc --kubeconfig="$KUBECONFIG" delete "$kind" "$name" -n "$check_namespace" &>/dev/null; then
      echo -e "    ${GREEN}✅ Deleted: $kind/$name${NC}"
      ((deleted_count++))
    else
      # Check if resource doesn't exist
      if ! oc --kubeconfig="$KUBECONFIG" get "$kind" "$name" -n "$check_namespace" &>/dev/null; then
        echo -e "    ${YELLOW}⚠️  Not found: $kind/$name (may have been already deleted)${NC}"
        ((not_found_count++))
      else
        echo -e "    ${RED}❌ Failed to delete: $kind/$name${NC}"
        ((error_count++))
      fi
    fi
  done < "$WORK_DIR/resources-list.txt"
  
  echo ""
  echo "Deletion summary:"
  echo "  - Successfully deleted: $deleted_count"
  echo "  - Not found (already deleted): $not_found_count"
  echo "  - Errors: $error_count"
  
  if [[ $error_count -gt 0 ]]; then
    echo -e "${RED}  ⚠️  Some resources failed to delete${NC}"
    return 1
  fi
  
  return 0
}

# Main execution
main() {
  # Check if we're connected to a hub cluster
  if ! oc get managedclusters &>/dev/null; then
    echo -e "${RED}Error: Not connected to a hub cluster or cannot access managedclusters${NC}"
    echo "Please ensure you're connected to the hub cluster and have proper permissions"
    exit 1
  fi
  
  # Verify the non-primary cluster exists
  if ! oc get managedcluster "$NON_PRIMARY_CLUSTER" &>/dev/null; then
    echo -e "${RED}Error: Managed cluster '$NON_PRIMARY_CLUSTER' not found${NC}"
    echo "Available managed clusters:"
    oc get managedclusters -o name 2>/dev/null | sed 's/^/  - /' || echo "  (could not list clusters)"
    exit 1
  fi
  
  # Get kubeconfig for non-primary cluster
  if ! get_cluster_kubeconfig "$NON_PRIMARY_CLUSTER"; then
    echo -e "${RED}Error: Failed to get kubeconfig for cluster $NON_PRIMARY_CLUSTER${NC}"
    exit 1
  fi
  
  # Verify namespace exists
  if ! oc --kubeconfig="$KUBECONFIG" get namespace "$VM_NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}  ⚠️  Namespace $VM_NAMESPACE does not exist on cluster $NON_PRIMARY_CLUSTER${NC}"
    echo "  Nothing to clean up"
    exit 0
  fi
  
  # Render helm template
  if ! render_helm_template; then
    echo -e "${RED}Error: Failed to render helm template${NC}"
    exit 1
  fi
  
  # Extract resources
  if ! extract_resources; then
    echo -e "${RED}Error: Failed to extract resources from helm template${NC}"
    exit 1
  fi
  
  # Confirm deletion
  echo ""
  echo "=========================================="
  echo -e "${YELLOW}WARNING: This will delete resources from namespace $VM_NAMESPACE on cluster $NON_PRIMARY_CLUSTER${NC}"
  echo "=========================================="
  echo ""
  read -p "Do you want to proceed with deletion? (yes/no): " confirm
  
  if [[ "$confirm" != "yes" ]]; then
    echo "Deletion cancelled"
    exit 0
  fi
  
  # Delete resources
  if ! delete_resources; then
    echo -e "${RED}Error: Some resources failed to delete${NC}"
    exit 1
  fi
  
  echo ""
  echo -e "${GREEN}✅ Cleanup completed successfully!${NC}"
  echo ""
  echo "Resources were deleted from:"
  echo "  - Cluster: $NON_PRIMARY_CLUSTER"
  echo "  - Namespace: $VM_NAMESPACE"
}

# Run main function
main "$@"

