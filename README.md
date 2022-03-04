# cloud-utils
Utilities to make it easy to work with cloud storage software 

## Object Storage Deployments
1. MinIO Object Storage
2. Ceph Storage
3. CORTX Object Storage

## Ceph Storage Deployment (Bare Metal)
1. Prepare 1 or N server nodes with disks where Ceph needs to deployed. 

2. Ensure root password-less-access between the nodes, has been setup.
 
3. Edit storage/ceph/ceph-adm/ceph-adm.conf and add your node details (Be careful to review)

4. Run following commands (Use --noprompt in case of automated deployment) 

   ```
   $ storage/ceph/ceph-adm/ceph-adm.sh [--noprompt] cleanup  
   $ storage/ceph/ceph-adm/ceph-adm.sh [--noprompt] install
   $ storage/ceph/ceph-adm/ceph-adm.sh [--noprompt] prepare
   $ storage/ceph/ceph-adm/ceph-adm.sh [--noprompt] config
   $ storage/ceph/ceph-adm/ceph-adm.sh [--noprompt] test
   ```
