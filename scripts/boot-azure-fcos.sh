#!/bin/bash

# Prefix that will go into every single item created in azure
# To remove everything run az group delete -n ${az_id}-group
az_id="aztestvm"

STREAM="stable"
STABLE_IMAGE="fedora-coreos-42.20250721.3.0-azure.x86_64.vhd.xz"
STABLE_IMAGE_UNCOMPRESSED="fedora-coreos-42.20250721.3.0-azure.x86_64.vhd"

butane="configs/simple.bu"
key=""
if [ -z "${key}" ]; then
	echo "Please, specify the public ssh key"
	exit 1
fi

set -euo pipefail
set -x

if [[ ! -f "${STABLE_IMAGE_UNCOMPRESSED}" ]]; then
    wget https://builds.coreos.fedoraproject.org/prod/streams/${STREAM}/builds/42.20250721.3.0/x86_64/fedora-coreos-42.20250721.3.0-azure.x86_64.vhd.xz
    unxz "fedora-coreos-42.20250721.3.0-azure.x86_64.vhd.xz"
fi

# REFACTOR THIS FROM /scripts/install_vm.sh
mkdir -p tmp
butane_name="$(basename ${butane})"
IGNITION_FILE="tmp/${butane_name%.bu}.ign"
IGNITION_CONFIG="$(pwd)/${IGNITION_FILE}"
bufile="./tmp/${butane_name}"
sed "s|<KEY>|${key}|g" $butane > ${bufile}
butane_args=()
if [[ -d ${butane%.bu} ]]; then
	butane_args=("--files-dir" "${butane%.bu}")
fi
podman run --interactive --rm --security-opt label=disable \
	--volume "$(pwd)":/pwd \
	--volume "${bufile}":/config.bu:z \
	--workdir /pwd \
	quay.io/coreos/butane:release \
	--pretty --strict /config.bu --output "/pwd/${IGNITION_FILE}" \
	"${butane_args[@]}"


az_region="eastus"
az_resource_group="${az_id}-group"
az_storage_account="${az_id}storageacct"
az_container="${az_id}-stg-container"
az_image_name="${az_id}-image"
az_image_blob="${az_image_name}.vhd"
gallery_name="${az_id}gallery"
gallery_image_definition="${az_id}-gallery-def"
vm_name="${az_id}-cvm"
vm_size="Standard_DC2as_v5"

# Create resource group
az group create \
    -l "${az_region}" \
    -n "${az_resource_group}"
# Create storage account for uploading FCOS image
az storage account create \
    -g "${az_resource_group}" \
    -n "${az_storage_account}"
# Retrieve connection string for storage account
cs=$(az storage account show-connection-string \
    -n "${az_storage_account}" \
    -g "${az_resource_group}" | jq \
    -r .connectionString)
# Create storage container for uploading FCOS image
az storage container create \
    --connection-string "${cs}" \
    -n "${az_container}"
# Upload image blob
az storage blob upload \
    --connection-string "${cs}" \
    -c "${az_container}" \
    -f "${STABLE_IMAGE_UNCOMPRESSED}" \
    -n "${az_image_blob}"

# Create an image gallery
az sig create \
    --resource-group "${az_resource_group}" \
    --gallery-name "${gallery_name}"

# Create a gallery image definition
az sig image-definition create \
    --resource-group "${az_resource_group}" \
    --gallery-name "${gallery_name}" \
    --gallery-image-definition "${gallery_image_definition}" \
    --publisher azure \
    --offer example \
    --sku standard \
    --features SecurityType=ConfidentialVmSupported \
    --os-type Linux \
    --hyper-v-generation V2

# Get the source VHD URI of OS disk
os_vhd_storage_account=$(az storage account list -g ${az_resource_group} | jq -r .[].id)

# Create a new image version
gallery_image_version="1.0.0"
az sig image-version create \
    --resource-group "${az_resource_group}" \
    --gallery-name "${gallery_name}" \
    --gallery-image-definition "${gallery_image_definition}" \
    --gallery-image-version "${gallery_image_version}" \
    --os-vhd-storage-account "${os_vhd_storage_account}" \
    --os-vhd-uri https://${az_storage_account}.blob.core.windows.net/${az_container}/${az_image_blob}

# Get gallery image id
gallery_image_id=$(az sig image-version show \
    --gallery-image-definition "${gallery_image_definition}" \
    --gallery-image-version "${gallery_image_version}" \
    --gallery-name "${gallery_name}" \
    --resource-group $az_resource_group | jq \
    -r .id)

# Create a VM with confidential computing enabled using the gallery image and an ignition config as custom-data
az vm create \
    --name "${vm_name}" \
    --resource-group $az_resource_group \
    --size "${vm_size}" \
    --image "${gallery_image_id}" \
    --admin-username core \
    --generate-ssh-keys \
    --custom-data "$(cat ${IGNITION_FILE})" \
    --enable-vtpm true \
    --public-ip-sku Standard \
    --security-type ConfidentialVM \
    --os-disk-security-encryption-type VMGuestStateOnly \
    --enable-secure-boot true
