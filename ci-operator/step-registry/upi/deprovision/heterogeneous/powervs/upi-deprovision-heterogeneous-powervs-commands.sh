#!/bin/bash

# TODO: Add code to deprovision powervs nodes
# Assuming that the var.tfvars used to provision the powervs nodes is preserved
echo "Invoking  upi deprovision heterogeneous powervs"
echo "Check if the IBMCLOUD_HOME_FOLDER exists"
if [ -d "$IBMCLOUD_HOME_FOLDER/ocp4-upi-compute-powervs" ]
then
    echo "Directory $IBMCLOUD_HOME_FOLDER/ocp4-upi-compute-powervs exists."
    # Invoke the destroy command
    cd $IBMCLOUD_HOME_FOLDER/ocp4-upi-compute-powervs && terraform destroy -var-file=var.tfvars
    # TODO: get the output of destroy command to know if the destroy completed successfully
else
    echo "Error: Directory $IBMCLOUD_HOME_FOLDER/ocp4-upi-compute-powervs does not exists."
fi
