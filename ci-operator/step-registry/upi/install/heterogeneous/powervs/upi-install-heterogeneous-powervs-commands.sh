#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
    echo "No additional workers requested"
    exit 0
fi

echo "Shared dir is ${SHARED_DIR} and cluster profile dir is ${CLUSTER_PROFILE_DIR}"

SHARED_DIR_FILES=$(ls ${SHARED_DIR})
CLUSTER_PROFILE_DIR_FILES=$(ls ${CLUSTER_PROFILE_DIR})
echo "Contents of shared dir are ${SHARED_DIR_FILES}"
echo "Contents of cluster profile are ${CLUSTER_PROFILE_DIR_FILES}"

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-10}
  local period=${3:-5}
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      return 1
    fi
    sleep "${period}m"
    ready_nodes=$(get_ready_nodes_count)
    if [ x"${ready_nodes}" == x"${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i) * (period) ))min)..."
  done
}

EXPECTED_NODES=$(( $(get_ready_nodes_count) + ADDITIONAL_WORKERS ))

echo "Cluster type is ${CLUSTER_TYPE}"

case "$CLUSTER_TYPE" in
*ibmcloud*)
  # Add code for ppc64le
  if [ "${ADDITIONAL_WORKER_ARCHITECTURE}" == "ppc64le" ]; then
      echo "Adding additional ppc64le nodes"
      REGION="${LEASED_RESOURCE}"
      IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
      SERVICE_NAME=power-iaas
      SERVICE_PLAN_NAME=power-virtual-server-group
      WORKSPACE_NAME=rdr-mac-${REGION}-n1

      PATH=${PATH}:/tmp
      mkdir -p ${IBMCLOUD_HOME_FOLDER}
      if [ -z "$(command -v ibmcloud)" ]; then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      fi

      function ic() {
        HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
      }

      # Check if jq,yq and openshift-install are installed
      if [ -z "$(command -v yq)" ]; then
      	echo "yq is not installed, proceed to installing yq"
      	curl -L "https://github.com/mikefarah/yq/releases/download/v4.30.5/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
          -o /tmp/yq && chmod +x /tmp/yq
      else
        echo "yq is already installed"
      fi

      if [ -z "$(command -v jq)" ]; then
        echo "jq is not installed, proceed to installing jq"
        curl -L "https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64" -o /tmp/jq && chmod +x /tmp/jq
      else
        echo "jq is already installed"
      fi

      if [ -z "$(command -v openshift-install)" ]; then
        echo "openshift-install is not installed, proceed to installing openshift-install"
        curl -L https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp/stable/ppc64le/openshift-install-linux.tar.gz -o /tmp/openshift-install && chmod +x /tmp/openshift-install
      else
        echo "openshift-install is already installed"
      fi

      ic version
      ic login --apikey @${CLUSTER_PROFILE_DIR}/ibmcloud-api-key -r ${REGION}
      ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas

      # create workspace for power from cli
      echo "Display all the variable values"
      echo "Region is ${REGION} Resource Group is ${RESOURCE_GROUP}"
      SERVICE_INSTANCE_OUTPUT=$(ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${REGION}" -g "${RESOURCE_GROUP}")

      SERVICE_INSTANCE_ID=$(echo "$SERVICE_INSTANCE_OUTPUT" | grep -oE 'GUID:[[:space:]]+[^:[:space:]]+' | awk '{print $2}')

      echo ${SERVICE_INSTANCE_ID}
      # After the workspace is created, invoke the automation code
      cd ${IBMCLOUD_HOME_FOLDER} && git clone -b release-${OCP_VERSION} https://github.com/IBM/ocp4-upi-compute-powervs.git

      # Set the values to be used for generating var.tfvars
      IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"
      export IC_API_KEY
      export PRIVATE_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-privatekey
      export PUBLIC_KEY_FILE=${CLUSTER_PROFILE_DIR}/ssh-publickey
      export POWERVS_SERVICE_INSTANCE_ID=${SERVICE_INSTANCE_ID}
      export INSTALL_CONFIG_FILE=${SHARED_DIR}/install-config.yaml
      export KUBECONFIG=${SHARED_DIR}/kubeconfig

      # Invoke create_var_file.sh to generate var.tfvars file
      cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/scripts && chmod a+x create-var-file.sh && ./create-var-file.sh

      # TODO:MAC check if the var.tfvars file is populated
      VARFILE_OUTPUT=$(cat ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars)
      echo "varfile_output is ${VARFILE_OUTPUT}"

      # copy the var.tfvars file and the POWERVS_SERVICE_INSTANCE_ID to ${SHARED_DIR} so that it can be used to destroy the created resources.
      cp ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars ${SHARED_DIR}/var.tfvars
      echo ${POWERVS_SERVICE_INSTANCE_ID} > ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID
      cat ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID
      cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs && terraform init -upgrade && terraform plan -var-file=var.tfvars && terraform apply -var-file=var.tfvars
  fi
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Wait for the nodes to become ready..."
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
if [ "${ret}" != "0" ]; then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi

exit 0
