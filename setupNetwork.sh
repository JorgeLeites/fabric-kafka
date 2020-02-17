#!/usr/bin/env bash

CHANNEL_NAME=mychannel
FABRIC_PATH=$PWD/tmp
PATH=$PATH:$PWD/bin

# Create fabric temp dir
echo -e "\nCreating farbic network temp dir..."
if [ -d "$FABRIC_PATH" ]; then
  rm -rf $FABRIC_PATH
fi
mkdir $FABRIC_PATH

if [ -d "${PWD}/artifacts/" ]; then
  ARTIFACTS_FOLDER=${PWD}/artifacts
else
  echo "Fabric artifacts are missing."
  exit
fi

echo 'Cryptogen Starts'
ls -l $ARTIFACTS_FOLDER

cp -r $ARTIFACTS_FOLDER/chaincode $FABRIC_PATH

cryptogen generate --config $ARTIFACTS_FOLDER/crypto-config.yaml
cp -r crypto-config $FABRIC_PATH

for file in $(find ${FABRIC_PATH} -iname *_sk); do
  echo $file
  dir=$(dirname $file)
  echo ${dir}
  mv ${dir}/*_sk ${dir}/key.pem
done
rm -rf $PWD/crypto-config

echo 'Configtxgen Starts'

cp $PWD/artifacts/configtx.yaml $FABRIC_PATH
pushd $FABRIC_PATH

configtxgen -channelID initchannel -profile TwoOrgsOrdererGenesis -outputBlock genesis.block

ls
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ${CHANNEL_NAME}.tx -channelID ${CHANNEL_NAME}
configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate Org1MSPanchors.tx -channelID ${CHANNEL_NAME} -asOrg Org1MSP
configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate Org2MSPanchors.tx -channelID ${CHANNEL_NAME} -asOrg Org2MSP
touch status_channeltx_complete
popd

###############################################

if [ -d "${PWD}/config" ]; then
  KUBECONFIG_FOLDER=${PWD}/config
else
  echo "Configuration files are not found."
  exit
fi

# Creating namespaces
echo -e "\nCreating required k8s namespaces..."
kubectl create -f ${KUBECONFIG_FOLDER}/namespaces.yaml

# Creating persistant volumes
echo -e "\nCreating persistant volumes..."
kubectl create -f ${KUBECONFIG_FOLDER}/kafka-pvs.yaml
kubectl create -f ${KUBECONFIG_FOLDER}/fabric-pvs.yaml

# Creating persistant volume claims
echo -e "\nCreating persistant volume claims..."
kubectl create -f ${KUBECONFIG_FOLDER}/kafka-pvcs.yaml
kubectl create -f ${KUBECONFIG_FOLDER}/fabric-pvcs.yaml

# Checking PVC status
checkPVCStatus() {
  if [ "$1" == "shared-pvc" ]; then
    if [ "$(kubectl get pvc -n fabric | grep $1 | awk '{print $2}')" == "Bound" ]; then
      echo "PVC $1:  bound!"
    fi
  else
    if [ "$(kubectl get pvc --all-namespaces | grep $1 | awk '{print $3}')" == "Bound" ]; then
      echo "PVC $1:  bound!"
    fi
  fi
}

PVCS="shared-pvc datadir-kafka-0 datadir-kafka-1 datadir-kafka-2 datadir-kafka-3"
for pvc in $PVCS
do
  checkPVCStatus $pvc
done


# Copy the required files(configtx.yaml, cruypto-config.yaml, sample chaincode etc.) into volume
echo -e "\nCreating Copy artifacts job..."
kubectl create -f ${KUBECONFIG_FOLDER}/job/0copy-artifacts.yaml

podOrg1=$(kubectl get pods -n org1 --selector=job-name=copyartifacts --output=jsonpath={.items..metadata.name})
podOrg2=$(kubectl get pods -n org2 --selector=job-name=copyartifacts --output=jsonpath={.items..metadata.name})
podOrdererOrg=$(kubectl get pods -n ordererorg1 --selector=job-name=copyartifacts --output=jsonpath={.items..metadata.name})
podOrg1STATUS=$(kubectl get pods -n org1 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})
podOrg2STATUS=$(kubectl get pods -n org2 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})
podOrdererOrgSTATUS=$(kubectl get pods -n ordererorg1 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})

while [ "${podOrg1STATUS}" != "Running" ] || [ "${podOrg2STATUS}" != "Running" ] || [ "${podOrdererOrgSTATUS}" != "Running" ]; do
  echo "Wating for container of copy artifact pod to run."
  echo "Current status of ${podOrg1} is ${podOrg1STATUS}"
  echo "Current status of ${podOrg2} is ${podOrg2STATUS}"
  echo "Current status of ${podOrdererOrg} is ${podOrdererOrgSTATUS}"
  sleep 5;
  if [[ "${podOrg1STATUS}" == *"Error"* ]] || [[ "${podOrg2STATUS}" == *"Error"* ]] || [[ "${podOrdererOrgSTATUS}" == *"Error"* ]]; then
    echo "There is an error in copyartifacts job. Please check logs."
    exit 1
  fi
  podOrg1STATUS=$(kubectl get pods -n org1 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})
  podOrg2STATUS=$(kubectl get pods -n org2 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})
  podOrdererOrgSTATUS=$(kubectl get pods -n ordererorg1 --selector=job-name=copyartifacts --output=jsonpath={.items..phase})
done

echo -e "${podOrg1} is now ${podOrg1STATUS}"
echo -e "${podOrg2} is now ${podOrg2STATUS}"
echo -e "${podOrdererOrg} is now ${podOrdererOrgSTATUS}"
echo -e "\nStarting to copy artifacts in persistent volume."
for file in $(ls ./tmp); do
  kubectl cp -n org1 ./tmp/$file $podOrg1:/shared/
  kubectl cp -n org2 ./tmp/$file $podOrg2:/shared/
  kubectl cp -n ordererorg1 ./tmp/$file $podOrdererOrg:/shared/
done

echo "Waiting for 10 more seconds for copying artifacts to avoid any network delay"
sleep 10
JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "copyartifacts" |awk '{print $2}')
JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "copyartifacts" |awk '{print $2}')
JOB_STATUS_ORDERER_ORG=$(kubectl get jobs -n ordererorg1 |grep "copyartifacts" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ] || [ "${JOB_STATUS_ORG2}" != "1/1" ] || [ "${JOB_STATUS_ORDERER_ORG}" != "1/1" ]; do
  echo "Waiting for copyartifacts job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "copyartifacts" | awk '{print $3}')
  POD_STATUS_ORG2=$(kubectl get pods -n org2 | grep "copyartifacts" | awk '{print $3}')
  POD_STATUS_ORDERER_ORG=$(kubectl get pods -n ordererorg1 | grep "copyartifacts" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]] || [[ "${POD_STATUS_ORG2}" == *"Error"* ]] || [[ "${POD_STATUS_ORDERER_ORG}" == *"Error"* ]]; then
      echo "There is an error in copyartifacts job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "copyartifacts" |awk '{print $2}')
  JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "copyartifacts" |awk '{print $2}')
  JOB_STATUS_ORDERER_ORG=$(kubectl get jobs -n ordererorg1 |grep "copyartifacts" |awk '{print $2}')
done
echo "Copy artifacts job completed"


# Setup zookeeper ensemble
echo -e "\nCreating Zookeeper service..."
kubectl create -f ${KUBECONFIG_FOLDER}/zookeeper
sleep 30

# Setup Kafka cluster
echo -e "\nCreating Kafka cluster service..."
kubectl create -f ${KUBECONFIG_FOLDER}/kafka
sleep 5

# Create services for all peers, ca, orderer
echo -e "\nCreating Fabric CA services..."
kubectl create -f ${KUBECONFIG_FOLDER}/ca
sleep 5

echo -e "\nCreating Fabric Orderer nodes..."
kubectl create -f ${KUBECONFIG_FOLDER}/orderer
sleep 5

echo -e "\nCreating Fabric peer nodes..."
kubectl create -f ${KUBECONFIG_FOLDER}/peer
sleep 5

echo -e "\nCreating Fabric CLI nodes..."
kubectl create -f ${KUBECONFIG_FOLDER}/cli
sleep 5

echo "Checking if all deployments are ready"

NUMPENDING=$(kubectl get deployments --all-namespaces -l app=hyperledger | awk '{print $6}' | grep 0 | wc -l | awk '{print $1}')
while [ "${NUMPENDING}" != "0" ]; do
  echo "Waiting on pending deployments. Deployments pending = ${NUMPENDING}"
  NUMPENDING=$(kubectl get deployments --all-namespaces -l app=hyperledger | awk '{print $6}' | grep 0 | wc -l | awk '{print $1}')
  sleep 1
done

ORDERER_POD=$(kubectl get pods -n ordererorg1 | grep orderer0 | awk '{print $1}')
while [ "$(kubectl logs -n ordererorg1 ${ORDERER_POD} | grep "Start phase completed successfully")" == "" ]; do
  echo "Waiting for orderer to start"
  sleep 1
done

# Generate channel artifacts using configtx.yaml and then create channel
echo -e "\nCreating a channel"
kubectl create -f ${KUBECONFIG_FOLDER}/job/1create-channel.yaml

JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "createchannel" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ]; do
  echo "Waiting for createchannel job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "createchannel" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]]; then
      echo "There is an error in createchannel job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "createchannel" |awk '{print $2}')
done
echo "Create Channel Completed Successfully"


# Join all peers on a channel
echo -e "\nCreating joinchannel job"
kubectl create -f ${KUBECONFIG_FOLDER}/job/2join-channel.yaml

JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "joinchannel" |awk '{print $2}')
JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "joinchannel" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ] || [ "${JOB_STATUS_ORG2}" != "1/1" ]; do
  echo "Waiting for joinchannel job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "joinchannel" | awk '{print $3}')
  POD_STATUS_ORG2=$(kubectl get pods -n org2 | grep "joinchannel" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]] || [[ "${POD_STATUS_ORG2}" == *"Error"* ]]; then
      echo "There is an error in joinchannel job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "joinchannel" |awk '{print $2}')
  JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "joinchannel" |awk '{print $2}')
done
echo "Join Channel Completed Successfully"

# Update channel anchor peers
echo -e "\nCreatiing updateanchor job"
kubectl create -f ${KUBECONFIG_FOLDER}/job/3update-anchor.yaml

JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "updateanchor" |awk '{print $2}')
JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "updateanchor" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ] || [ "${JOB_STATUS_ORG2}" != "1/1" ]; do
  echo "Waiting for updateanchor job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "updateanchor" | awk '{print $3}')
  POD_STATUS_ORG2=$(kubectl get pods -n org2 | grep "updateanchor" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]] || [[ "${POD_STATUS_ORG2}" == *"Error"* ]]; then
      echo "There is an error in updateanchor job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "updateanchor" |awk '{print $2}')
  JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "updateanchor" |awk '{print $2}')
done
echo "Update Channel Anchor Peer  Completed Successfully"


# Install chaincode on each peer
echo -e "\nCreating chaincodeinstall job"
kubectl create -f ${KUBECONFIG_FOLDER}/job/4install-chaincode.yaml

JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "chaincodeinstall" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ]; do
  echo "Waiting for chaincodeinstall job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "chaincodeinstall" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]]; then
      echo "There is an error in chaincodeinstall job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "chaincodeinstall" |awk '{print $2}')
done
echo "Chaincode Install Completed Successfully"


# Instantiate chaincode on channel
echo -e "\nCreating chaincodeinstantiate job"
kubectl create -f ${KUBECONFIG_FOLDER}/job/5instantiate-chaincode.yaml

JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "chaincodeinstantiate" |awk '{print $2}')
JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "chaincodeinstantiate" |awk '{print $2}')
while [ "${JOB_STATUS_ORG1}" != "1/1" ] || [ "${JOB_STATUS_ORG2}" != "1/1" ]; do
  echo "Waiting for chaincodeinstantiate job to complete"
  sleep 1;
  POD_STATUS_ORG1=$(kubectl get pods -n org1 | grep "chaincodeinstantiate" | awk '{print $3}')
  POD_STATUS_ORG2=$(kubectl get pods -n org2 | grep "chaincodeinstantiate" | awk '{print $3}')
    if [[ "${POD_STATUS_ORG1}" == *"Error"* ]] || [[ "${POD_STATUS_ORG2}" == *"Error"* ]]; then
      echo "There is an error in chaincodeinstantiate job. Please check logs."
      exit 1
    fi
  JOB_STATUS_ORG1=$(kubectl get jobs -n org1 |grep "chaincodeinstantiate" |awk '{print $2}')
  JOB_STATUS_ORG2=$(kubectl get jobs -n org2 |grep "chaincodeinstantiate" |awk '{print $2}')
done
echo "Chaincode Instantiation Completed Successfully"

sleep 15
echo -e "\nNetwork Setup Completed !!"
