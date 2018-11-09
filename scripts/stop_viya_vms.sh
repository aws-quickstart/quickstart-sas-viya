#!/bin/bash

# Run this script to stop all Viya services and all VMs where they are running.
#
# Use this script in combination with start_viya_vms.sh to save AWS resource costs
# when the SAS Viya environment is not actively in use.

# Expect the script to run about 10 minutes

#
# execute the virk stop services playbook
#
echo "Stopping Viya services..."
pushd ~/sas_viya_playbook
   # It is necessary to disable the automatic service restarts.
   # Without disabling the service restart, the services will come up as each VM restarts.
   # Instead, we want to control the order at restart.
   ansible-playbook virk/playbooks/service-management/viya-services-disable.yml
   # This stops the services in the correct order
   ansible-playbook virk/playbooks/service-management/viya-services-stop.yml
popd

#
# get all the VMs of the stack, except the ansible controller
#
echo "Getting list of VMs..."
IDS=$(aws --region {{AWSRegion}} cloudformation describe-stack-resources --stack-name {{CloudFormationStack}} --query 'StackResources[?ResourceType==`AWS::EC2::Instance`  && LogicalResourceId!=`AnsibleController`].PhysicalResourceId' --output text)

#
# stop the VMs
#
echo "Stopping VMs..."
aws --region {{AWSRegion}} ec2 stop-instances --instance-ids ${IDS}