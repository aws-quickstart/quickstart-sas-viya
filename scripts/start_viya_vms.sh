#!/bin/bash

# Run this script to start all the Viya VMs and Viya services.
#
# Use this script in combination with stop_viya_vms.sh to save AWS resource costs
# when the SAS Viya environment is not actively in use.

# Expect the script to run about 10 minutes

#
# get all the VMs of the stack, except the ansible controller
#
echo "Getting list of VMs..."
IDS=$(aws --region {{AWSRegion}} cloudformation describe-stack-resources --stack-name {{CloudFormationStack}} --query 'StackResources[?ResourceType==`AWS::EC2::Instance`  && LogicalResourceId!=`AnsibleController`].PhysicalResourceId' --output text)
# transform into array
IFS=" " IDs=(${IDS})
unset IFS


#
# start the VMs
#
echo "Starting VMs..."
aws --region {{AWSRegion}} ec2 start-instances --instance-ids ${IDS}


#
# wait for the VMs to be up
#
STATUS=
while [ "$STATUS" = "" ]; do
   sleep 3
   if [ -z "$(aws --region {{AWSRegion}} ec2 describe-instances --instance-ids $IDS --query Reservations[*].Instances[*].State.Name --output text | grep -q -v 'running')" ] ; then
     STATUS='ok'
   fi

   # make sure sshd is up on each VM
   for ID in ${IDs[@]}; do
      IP=$(aws ec2 --region {{AWSRegion}} describe-instances --instance-id $ID --query Reservations[*].Instances[*].PrivateIpAddress --output text)
      RC=-1
      until [ $RC = 0 ]; do
        sleep 3
        # try to log in
        ssh -q $IP exit
        RC=$?
      done
   done
done


#
# execute the virk start services playbook
#
echo "Starting Viya services..."
pushd ~/sas_viya_playbook
   ansible-playbook virk/playbooks/service-management/viya-services-start.yml
popd

