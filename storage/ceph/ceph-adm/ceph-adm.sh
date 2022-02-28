#!/bin/bash

set -E

function process_args {
    [ -z "$MOD_NODES" || -z "$RGW_NODES" || -z "$OSD_DISKS" ] && usage

    # Derived from config
    OSD_NODES=($(echo ${OSD_DISKS[@]%%:*} | xargs -n1 | sort -u | xargs | sed "s# # #g"))
    NODES=$(echo "${MON_NODES[@]} ${RGW_NODES[@]} ${OSD_NODES[@]}" | xargs -n1 | sort | uniq | xargs)
    MON_NODE_IP=$(host ${MON_NODES[0]} | awk '{print $4}')
    CEPH_ADM="cephadm shell -- ceph"
    let NUM_PG=32 # OR can be ${#OSD_DISKS[@]}*16

    [ -z "$CLUSTER" ] && CLUSTER=ceph1
    [ -z "$CEPH_RELEASE" ] && CEPH_RELEASE=octopus
    [ -z "$CEPH_USER" ] && CEPH_USER=cephuser
    export OSD_NODES NODES MON_NODE_IP CEPH_ADM CLUSTER CEPH_RELEASE CEPH_USER
}

# Execute Command
function run {
    if [ ! -z "$noprompt" ]; then
        echo -e "\n\nceph-adm> $*"
        $*
    else
        echo -ne "\n\nceph-adm> $*"
        read a
        [ "$a" = "c" -o "$a" = "C" ] && return 1
        $*
    fi
    [ $? -ne 0 ] && exit 1
    return 0
}

function prepare {
    # Ensure /etc/hosts has all the nodes
    #[ -f $HOME/.ssh/id_dsa ] || ssh-keygen -t dsa
    for node in $NODES; do
        run ssh-copy-id root@$node 2>/dev/null
        run ssh root@$node "
            timedatectl set-timezone \"Asia/Kolkata\";
            yum -y install chrony;
            systemctl enable --now chronyd;
            sudo timedatectl set-ntp true"

    done

    host_error=$(
        for node in $NODES; do
            ssh root@$node "
                for node in $NODES; do
                    grep -q \$node /etc/hosts || echo \"\$node missing in $node:/etc/hosts\";
                done"
        done)
    [ -z "$host_error" ] || { echo "error: $host_error" && exit 1; }
}

function install {
    for node in $NODES; do
        run ssh root@$node "
            curl --silent --remote-name --location https://github.com/ceph/ceph/raw/octopus/src/cephadm/cephadm;
            chmod +x ./cephadm;
            ./cephadm add-repo --release $CEPH_RELEASE;
            dnf -y install cephadm;
            dnf install -y podman;
            cephadm install ceph-common ceph-osd;
            mkdir -p /etc/ceph;
            ./cephadm install"
    done
}

function config_bootstrap {
    run sudo cephadm bootstrap --mon-ip $MON_NODE_IP --allow-overwrite --allow-fqdn-hostname

    sleep 1
    for node in $NODES; do
        run sudo ssh-copy-id -f -i /etc/ceph/ceph.pub root@$node;
    done

    for node in $NODES; do
        node_ip=$(host $node | awk '{print $4}')
        run sudo ceph orch host add $node $node_ip
    done

    #run sudo scp /etc/ceph/ceph.client.admin.keyring $node:/etc/ceph/;
    run sudo ceph orch host ls
}

function config_mon {
    run sudo ceph orch apply mon ${#MON_NODES[@]}
    sleep 1
    for node in ${MON_NODES[@]}; do
        run sudo ceph orch apply mon $node;
        #run sudo $CEPH_ADM orch host label add $node mon;
        sleep 2
    done;
    run sudo ceph orch host ls
}

function config_osd {
    ### OSD Setup ###
    for osd in ${OSD_DISKS[@]}; do
        run sudo ceph orch daemon add osd $osd;
    done

    sleep 1
    run sudo ceph -s;
    run sudo ceph osd tree;
    run sudo ceph osd dump;

    #run sudo ceph osd pool create pool1 $NUM_PG;
    #run sudo ceph osd pool set pool1 min_size 1;
    #run sudo ceph osd pool set pool1 size 2;
}

function config_rgw {
    ### RGW Setup ###
#    for node in ${RGW_NODES[@]}; do
#        ssh root@$node grep -q "client.rgw" /etc/ceph/ceph.conf;
#        if [ $? -ne 0 ]; then
#            cat > /tmp/$$ <<EOF
#
#[client.rgw.$node]
#    rgw frontends = beast port=7480
#    log file = /var/log/ceph/ceph-client.rgw.log
#EOF
#            run scp /tmp/$$ root@$node:/tmp/$$
#            run ssh root@$node "cat /tmp/$$ >> /etc/ceph/ceph.conf"
#        fi
#    done
    rgw_spec="${#RGW_NODES[@]} ${RGW_NODES[@]}"
    echo -n "ceph_setu> sudo ceph orch daemon add rgw default default --port 7480 --placement \"$rgw_spec\""
    [ -z "$noprompt" ] && read
    sudo ceph orch daemon add rgw default default --port 7480 --placement "$rgw_spec"

    run ssh root@${RGW_NODES[0]} "
        radosgw-admin user create --uid=$CEPH_USER --display-name=\"$CEPH_USER\";
        radosgw-admin key create --uid=$CEPH_USER --key-type=s3 --access-key ${CEPH_USER}AccessKey --secret-key ${CEPH_USER}SecretKey"
}

function config_check {
    run sudo ceph log last cephadm
    run sudo ceph orch ls
    run sudo ceph orch ps
    run sudo ceph -s;
    run sudo ceph health;
    run sudo ceph status;
    for node in $NODES; do
        run sudo ceph cephadm check-host $node
    done
}

function cleanup {
    run sudo ceph orch pause
    run sudo ceph osd down --ids=all
    run sudo ceph osd rm --ids=all;
    run sudo ceph orch ps;
    sleep 1

    HOSTS=$(sudo ceph orch host ls | grep -v HOST | awk '{ print $1 }')
    for node in ${HOSTS}; do
        run sudo ceph orch host rm $node
        run sudo ceph orch osd rm status
    done

    run sudo ceph fsid
    fsid=$(sudo ceph fsid)
    run sudo cephadm rm-cluster --force --fsid $fsid

    for node in ${OSD_NODES[@]}; do
        run ssh root@$node "
            volumes=\$(lvdisplay -c | grep ceph | cut -d: -f2);
            for v in \$volumes; do lvremove -f \$v; done"
    done
    for s in ${OSD_DISKS[@]}; do run ssh root@${s%%:*} sudo wipefs -a ${s##*:}; done

    for node in $NODES; do
        run ssh root@$node "rm -rf /var/lib/ceph/*"
        containers=$(ssh root@$node "podman ps" | grep -v CONTAINER | awk '{ print $1 }')
        [ ! -z "$containers" ] &&
            run ssh root@$node "for cid in $containers; do podman rm -f \$cid; done"
    done
}

function setup_test_user {
    run ssh root@${RGW_NODES[0]} radosgw-admin user list
    ssh root@${RGW_NODES[0]} radosgw-admin user list | grep -q main
    if [ $? -eq 0 ]; then
        echo "User main exists. Skipping creating user"
    else
        run ssh root@${RGW_NODES[0]} "
            radosgw-admin user create --uid=main --display-name=main --key-type=s3 --access-key mainAccessKey --secret-key mainSecretKey;
            radosgw-admin user create --uid=alt --display-name=alt --key-type=s3 --access-key altAccessKey --secret-key altSecretKey"
    fi
}

function test_s3test {
    setup_test_user

    [ ! -d s3 ] && run mkdir -p s3
    if [ ! -d s3/s3-tests ]; then
        run git clone https://github.com/ceph/s3-tests.git s3/s3-tests
        run pushd s3/s3-tests
        #run sudo yum install python-virtualenv
        run ./bootstrap
    else
        run pushd s3/s3-tests
    fi

    cat > ./s3-tests.conf <<EOF
[DEFAULT]
host = ${RGW_NODES[0]}
port = 7480

is_secure = no

[fixtures]
bucket prefix = s3-test-$$

[s3 main]
user_id = main
display_name = main
access_key = mainAccessKey
secret_key = mainSecretKey

[s3 alt]
user_id = alt
display_name = alt
access_key = altAccessKey
secret_key = altSecretKey
EOF

    export S3TEST_CONF=s3-tests.conf
    run cat ./s3-tests.conf
    run export S3TEST_CONF=s3-tests.conf
    run ./virtualenv/bin/nosetests -v --collect-only
    run popd
}

# s3cmd test
function setup_s3cmd {
    setup_test_user
    rpm -qa | grep -q s3cmd || sudo yum install s3cmd

    #[ ! -d s3 ] && run mkdir -p s3
    #[ ! -d s3/s3cmd ] && run git clone https://github.com/s3tools/s3cmd.git s3/s3cmd
    cat > ~/.s3cfg <<EOF
[default]
access_key = mainAccessKey
secret_key = mainSecretKey
host_base = ${RGW_NODES[0]}:7480
host_bucket = ${RGW_NODES[0]}:7480
use_https = False
EOF
    run cat ~/.s3cfg
}

function test_s3cmd {
    setup_s3cmd

    run s3cmd mb s3://bucket-1.$$
    run s3cmd ls
    run s3cmd put /etc/hosts s3://bucket-1.$$/
    run s3cmd ls s3://bucket-1.$$/
    run s3cmd mb s3://bucket-2.$$/
    run s3cmd cp s3://bucket-1.$$/hosts s3://bucket-2.$$/
    run s3cmd cp s3://bucket-1.$$/hosts s3://bucket-2.$$/
    run s3cmd ls s3://bucket-2.$$/
    run mkdir -p /tmp/dir-1.$$/dir-2.$$/dir-3.$$
    run touch /tmp/dir-1.$$/dir-2.$$/dir-3.$$/foo
    run s3cmd sync /tmp/dir-1.$$ s3://bucket-1.$$/
    run s3cmd put /etc/hosts s3://bucket-1.$$/dir-1.$$
    run s3cmd la
    run s3cmd rm s3://bucket-1.$$/dir-1.$$/hosts
    run s3cmd del -r --force s3://bucket-1.$$/
    run s3cmd rb s3://bucket-1.$$/
    run s3cmd del -r --force s3://bucket-2.$$/
    run s3cmd rb s3://bucket-2.$$/
}

function usage {
    echo "usage: $0 [-c <ceph-adm.conf>] [--noprompt] <command>"
    echo "where:"
    echo "<command> can be one of the following"
    echo "          {all|prepare|cleanup|install|config <phase>|test <type>"
    echo "<phase>   can be bootstrap|mon|osd|rgw|check"
    echo "<type>    can be s3test|s3cmd|awscli"
    exit 1
}

### Main ###
SCRIPT_DIR=$(dirname $0)

#### Args ####
export q=
export noprompt=
case $1 in
    -h | --help ) usage;;
    -c ) shift 1; [ ! -f "$1" ] && source "$1"; shift 1;;
    -q ) export q="-q"; shift 1;;
    --noprompt ) export noprompt=1; shift 1;;
esac

process_args

case $1 in
    prepare ) prepare ;;
    cleanup ) cleanup ;;
    install ) install ;;
    config )
        shift 1;
        phases="$*"
        [ -z "$phases" ] && phases="bootstrap mon osd rgw check"

        for phase in $phases; do
            type config_$phase 2>&1 > /dev/null || {
                echo "error: invalid input $phase"; usage;
            }
            config_$phase
            sleep 2
        done
        ;;

    test )
        shift 1
        if [ -z "$1" ]; then
            test_s3test
            test_s3cmd
        else
            type test_$1 2>&1 > /dev/null || {
                echo "error: invalid input test_$1"; usage;
            }
            test_$1
        fi
        ;;

    all ) prepare; cleanup; install; config; test_s3;;
    * ) usage;;
esac
