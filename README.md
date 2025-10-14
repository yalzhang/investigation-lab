# Investigations for Confidential Clusters

Work in progress documents about Confidential Clusters.

## Generate a key
```bash
ssh-keygen -f coreos.key
```

## Start fcos VM
```bash
scripts/install_vm.sh  -b config.bu -k "$(cat coreos.key.pub)"
```

## Remove fcos VM
```bash
scripts/uninstall_vm.sh  -n <vm_name>"
```

## Example with a local VM, attestation and disk encryption

Currently, ignition does not support encrypting the disk using trustee (see this 
[RFC](https://github.com/coreos/ignition/issues/2099) for more details). Therefore, we need to build a custom initramfs
which contains the trustee attester, and the KBS information hardcoded in the setup script.

Build the Fedora CoreOS or Centos Stream CoreOS image with the custom initrd:
```bash
cd coreos
# Centos Stream CoreOS image
just os=scos build oci-archive osbuild-qemu
# Fedora CoreOS image
just build oci-archive osbuild-qemu
```

### Create local Trustee deployment

Generate the key pair for Trustee:
```bash
scripts/gen_key.sh
```

Create trustee and helper containers for the setup:
```bash
sudo podman kube play trustee.yaml
```
The pods exposes 3 ports:
 - `8080`: for the KBS and Trustee
 - `8000`: serving the ignition file with the clevis configuration
 - `5001`: serving the registration endpoint for the AK

The script `scripts/populate-local-kbs.sh` populate the local KBS.
```bash
scripts/populate-local-kbs.sh
```

You can now launch the VM by exposing the trustee IP (for example, using the IP of `virbr0`).
```bash
export TRUSTEE_ADDR=192.168.122.1
scripts/install_vm.sh -k coreos.key.pub -b configs/ak.bu -i $(pwd)/coreos/fcos-qemu.x86_64.qcow2 -n <VM_NAME>
```

## Start fcos CVM in Azure
Note the az command line tool is needed for this script to work
properly. More information under the [ms docs](
https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest).
```bash
scripts/boot-azure-fcos.sh -k "$(cat coreos.key.pub)"
```

## Remove fcos CVM in Azure
This step will depend on the value of `az_id` that was set in the script
mentioned above. All the resources were created under the same resource
group. The only thing you need to do to undo all of that is removing the
resource group, which will be `"${az_id}-group"`; `aztestvm-group` by
default.

So just:
```bash
az group delete -n ${az_id}-group
```
