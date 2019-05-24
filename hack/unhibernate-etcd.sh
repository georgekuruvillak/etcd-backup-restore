#!/bin/bash
set -ue
function getNamespaces()
{
    namespaces=`kubectl get ns -o custom-columns=NAME:.metadata.name | tail -n +2`
    echo "${namespaces[@]}"
}

function getShootsInNamespace()
{
    local namespace=$1
    local shoots=`kubectl get shoot -n ${namespace} -o custom-columns=NAME:.metadata.name | tail -n +2`
    echo "${shoots[@]}"
}

function processShoot()
{
    local shoot=$1
    local namespace=$2
    local shootJson=`kubectl get shoot $shoot -n ${namespace} -o json`
    if [ "$?" != "0" ] | [ "$shootJson" == "" ];
    then 
        echo "Shoot information not available for ${shoot}/${namespace}."
        return 
    fi
    local hibernation_status=`echo -n ${shootJson} | jq .spec.hibernation.enabled`
    if [ "$hibernation_status" != "true" ]
    then
        echo "${shoot}/${namespace} is not hibernated. Skipping forced migration."
        return
    fi
    
    if [ "${skip_reconcile_check}" != "" ]
    then
        local reconcile_enabled=`echo -n ${shootJson} | jq .metadata.annotations | grep 'shoot.garden.sapcloud.io/ignore' | wc -l`
        if [ ! "${reconcile_enabled}" == "0" ]
        then
            echo "${shoot}/${namespace} is not reconciled. Skipping forced migration."
            return
        fi
    fi
    
    local seed=`echo -n ${shootJson} | jq .spec.cloud.seed | sed s/\"//g`
    echo "Fetching kubeconfig for seed cluster ${seed}."
    fetchKubeconfigForSeed ${seed}
    if [[ ! -e $KUBECONFIGS_DIR/seed-${seed}.kubeconfig ]]
    then
        echo "Failed to fetch kubeconfig for seed ${seed}"
        return
    fi
    
    projectname=`echo ${namespace} | cut -d "-" -f 2-`
    namespace_in_seed=`echo -n ${shootJson} | jq .status.technicalID | sed s/\"//g`
    has_etcd_main=`kubectl get statefulset etcd-main -n ${namespace_in_seed} --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig | wc -l`
    if [ "${has_etcd_main}" == "0" ]
    then
        echo "Shoot ${shoot}/${namespace} does not have etcd-main statefulset. Cannot migrate."
        return
    fi
    echo "Checking migration status for shoot ${shoot}/${namespace}."
    status=`checkMigrationStatus $namespace_in_seed ${seed}`
    if [ "${status}" == "DONE" ]
    then
        echo "Migration has already successful. Skipping shoot ${shoot}/${namespace}."
        return
    fi
    echo "Starting migration of shoot ${shoot}/${namespace}."
    
    if [ "${dryrun}" == "" ]
    then
        migrateShootEtcd $namespace_in_seed $seed
    else
        echo "${namespace}/${shoot}" >> hibernates-shoots.txt 
    fi
    echo "Completed migration of shoot ${shoot}."
}

function migrateShootEtcd()
{
    local namespace=$1
    local seed=$2
    kubectl -n ${namespace} scale statefulset/etcd-main --replicas=1 --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig
    waitTillMigrationCompleted ${namespace} ${seed}
    kubectl -n ${namespace} scale statefulset/etcd-main --replicas=0 --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig

}

function waitTillMigrationCompleted()
{
    local namespace=$1
    local seed=$2
    old_data_dir=/var/etcd/old-data
    migration_marker=$old_data_dir/migration.marker
    kubectl exec -it etcd-main-0 -c etcd -n ${namespace} --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig -- ls ${migration_marker}
    while [ "$?" != "0" ]
    do
        sleep 5
        kubectl exec -it etcd-main-0 -c etcd -n ${namespace} --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig -- ls ${migration_marker}
    done
}

function checkMigrationStatus()
{
    local namespace=$1
    local seed=$2
    etcd_pvc_count=`kubectl -n ${namespace} --kubeconfig=$KUBECONFIGS_DIR/seed-${seed}.kubeconfig get pvc | grep "main-etcd" | wc -l`
    if [[ "${etcd_pvc_count}" == 2 ]]
    then
        echo "DONE"
        return
    fi
    echo "PENDING"
}

function fetchKubeconfigForSeed()
{
    local seed=$1
    if [[ -e $KUBECONFIGS_DIR/seed-${seed}.kubeconfig ]]
    then
        return
    fi
    local seedJson=`kubectl get seed ${seed} -o json`
    local secretRefName=`echo -n ${seedJson} | jq .spec.secretRef.name | sed s/\"//g`
    local secretRefNamespace=`echo -n ${seedJson} | jq .spec.secretRef.namespace | sed s/\"//g`
    kubectl get secret ${secretRefName} -n ${secretRefNamespace} -o json | jq .data.kubeconfig | sed s/\"//g | base64 -d > $KUBECONFIGS_DIR/seed-${seed}.kubeconfig
}

function processNamespace()
{
    local namespaces=("$@")
    echo "Namespaces: ${namespaces[@]}"
    for namespace in ${namespaces}
    do
        declare -a shoots
        echo "Fetching shoots in ${namespace}."
        shoots=`getShootsInNamespace ${namespace}`
        if [ "${shoots}" == "" ] | [ "${#shoots[@]}" == "0" ];
        then
            continue
        fi
        for shoot in ${shoots}
        do  
            echo "Processing shoot ${shoot} in ${namespace}"
            processShoot ${shoot} ${namespace}
        done
    done
}


############### SCRIPT STARTS HERE. ###################
namespaces=()
if [ ! -z "${1-}" ]
then
    export KUBECONFIG=$1
fi
KUBECONFIGS_DIR=`pwd`/kubeconfigs
if [ ! -d $KUBECONFIGS_DIR ]
then
    mkdir -p $KUBECONFIGS_DIR
fi
groupsize=${2-2}
dryrun=${3-}
skip_reconcile_check=${4-}
# I fetch namespaces as I was not able to work with tuple of name,namespace for shoot in bash. 
echo "Fetching namespaces in garden cluster."
namespaces=`getNamespaces`
ns_count=`echo ${namespaces[@]} | wc -w`
pids=()
for i in `seq 0 $groupsize $ns_count`
do
  part=`echo ${namespaces[@]} | cut -d " " -f $(( i+1 ))-$(( i+groupsize ))`
  processNamespace "${part[@]}" &
  pid=$!
  pids+=( $pid )
done
echo "Parallel threads: ${#pids[@]}"
for i in ${pids[@]}
do 
    wait $i
done

