#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ "${ADDITIONAL_WORKERS}" == "0" ]; then
    echo "No additional workers requested"
    exit 0
fi

if [ "${ADDITIONAL_WORKERS_DAY2}" != "true" ]; then
    echo "Skipping as the additional nodes have been provisioned at installation time."
    exit 0
fi

echo "Additional worker vm type is ${ADDITIONAL_WORKER_VM_TYPE}"
echo "Shared dir is ${SHARED_DIR} and cluster profile dir is ${CLUSTER_PROFILE_DIR}"

SHARED_DIR_FILES=$(ls ${SHARED_DIR})
CLUSTER_PROFILE_DIR_FILES=$(ls ${CLUSTER_PROFILE_DIR})
echo "Contents of shared dir are ${SHARED_DIR_FILES}"
echo "Contents of cluster profile are ${CLUSTER_PROFILE_DIR_FILES}"
#CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
#BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

#echo "Cluster name and Base Domain is ${CLUSTER_NAME} ${BASE_DOMAIN}"

function approve_csrs() {
  while [[ ! -f '/tmp/scale-out-complete' ]]; do
    sleep 30
    echo "approve_csrs() running..."
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' \
      | xargs --no-run-if-empty oc adm certificate approve || true
  done
}

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
      IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
      SERVICE_NAME=power-iaas
      SERVICE_PLAN_NAME=power-virtual-server-group
      WORKSPACE_NAME=rdr-mac-$REGION-n1 # TODO: Should this be an env variable or some randomly generated name based on the zone?
      OPENSHIFT_CLIENT_TARBALL=""

      mkdir -p ${IBMCLOUD_HOME_FOLDER}
      if [ -z "$(command -v ibmcloud)" ]; then
        echo "ibmcloud CLI doesn't exist, installing"
        curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
      fi

      function ic() {
        HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
      }

      ic version
      ic login --apikey @${CLUSTER_PROFILE_DIR}/ibmcloud-api-key -r ${REGION}
      ic plugin install -f cloud-internet-services vpc-infrastructure cloud-object-storage power-iaas

      # create workspace for power from cli
      echo "Display all the variable values"
      echo "Region is ${REGION} Zone is ${ZONE} Resource Group is ${RESOURCE_GROUP}" #TODO: rename to RESOURCE_GROUP
      SERVICE_INSTANCE_OUTPUT=$(ic resource service-instance-create "${WORKSPACE_NAME}" "${SERVICE_NAME}" "${SERVICE_PLAN_NAME}" "${REGION}" -g "${RESOURCE_GROUP}")

      SERVICE_INSTANCE_ID=$(echo "$SERVICE_INSTANCE_OUTPUT" | grep -oE 'GUID:[[:space:]]+[^:[:space:]]+' | awk '{print $2}')

      echo ${SERVICE_INSTANCE_ID}
      # After the workspace is created, invoke the automation code
      cd ${IBMCLOUD_HOME_FOLDER} && git clone -b release-${OCP_VERSION} https://github.com/IBM/ocp4-upi-compute-powervs.git

      # Check if the terraform is of required version

      # Populate the values in vars.tfvars
      IC_API_KEY="$(< "${CLUSTER_PROFILE_DIR}/ibmcloud-api-key")"

      # TODO: Should ssh keys ideally be copied from some secrets?
      # copy public and private key files to the data directory
      SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
      SSH_PUB_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-publickey
      cp ${SSH_PUB_KEY_PATH} ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/compute_id_rsa.pub
      cp ${SSH_PRIV_KEY_PATH} ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/data/compute_id_rsa

      sed -i -e "s/\(vpc_name.*=\).*/\1$ZONE/" \
      -e "s/\(vpc_region.*=\).*/\1$REGION/" \
      -e "s/\(vpc_zone.*=\).*/\1$ZONE/" \
      -e "s/\(ibmcloud_api_key.*=\).*/\1$IC_API_KEY/" \
      -e "s/\(powervs_service_instance_id.*=\).*/\1$SERVICE_INSTANCE_ID/" \
      -e "s/\(powervs_region.*=\).*/\1$REGION/" \
      -e "s/\(powervs_zone.*=\).*/\1$ZONE/" \
      -e "s/\(openshift_client_tarball.*=\).*/\1$OPENSHIFT_CLIENT_TARBALL/" ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars

      VARFILE_OUTPUT=$(cat ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars)
      echo "varfile_output is ${VARFILE_OUTPUT}"
      # save the var.tfvars file to a temporary location so that it can be used to destroy the created resources. once the destroy is completed, the file can be deleted from the temporary location
      #cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs && terraform init -upgrade && terraform plan -var-file=var.tfvars && terraform apply -var-file=var.tfvars
      #TODO: get the output of apply command to know if the deploy completed successfully
      
  fi
;;
*)
  echo "Adding workers with a different ISA for jobs using the cluster type ${CLUSTER_TYPE} is not implemented yet..."
  exit 4
esac

echo "Wait for the nodes to become ready..."
approve_csrs &
wait_for_nodes_readiness ${EXPECTED_NODES}
ret="$?"
if [ "${ret}" != "0" ]; then
  echo "Some errors occurred, exiting with ${ret}."
  exit "${ret}"
fi
# let the approve_csr function finish
touch /tmp/scale-out-complete
if [ -z "${SCALE_IN_ARCHITECTURES}" ]; then
  echo "No scale-in architectures specified. Continuing..."
  exit 0
fi

exit 0
