#!/bin/bash

# var.tfvars used to provision the powervs nodes is copied to the ${SHARED_DIR}
echo "Invoking  upi deprovision heterogeneous powervs"
echo "Check if the var.tfvars exists in ${SHARED_DIR}"
if [ -f "${SHARED_DIR}/var.tfvars" ]
then
    IBMCLOUD_HOME_FOLDER=/tmp/ibmcloud
    mkdir -p ${IBMCLOUD_HOME_FOLDER}
    cd ${IBMCLOUD_HOME_FOLDER} && git clone -b release-${OCP_VERSION} https://github.com/IBM/ocp4-upi-compute-powervs.git
    # copy the var.tfvars file from ${SHARED_DIR}
    cp ${SHARED_DIR}/var.tfvars ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs/var.tfvars
    # Invoke the destroy command
    cd ${IBMCLOUD_HOME_FOLDER}/ocp4-upi-compute-powervs && terraform destroy -var-file=var.tfvars

    if [ -z "$(command -v ibmcloud)" ]; then
      echo "ibmcloud CLI doesn't exist, installing"
      curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
    fi

    function ic() {
      HOME=${IBMCLOUD_HOME_FOLDER} ibmcloud "$@"
    }
    # TODO: Delete the workspace created
    SERVICE_ID=$(cat ${SHARED_DIR}/POWERVS_SERVICE_INSTANCE_ID)
    ic resource service-instance-delete ${SERVICE_ID} -g ${RESOURCE_GROUP} --force --recursive
else
    echo "Error: File ${SHARED_DIR}/var.tfvars does not exists."
fi
