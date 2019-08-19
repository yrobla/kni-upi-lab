#!/bin/bash

SETTINGS_FILE="settings.env"

usage() {
    cat <<-EOM
    Parse the manifest files in the cluster director

    Usage:
        $(basename "$0") [-h] [-m manfifest_dir]  
            Parse manifest files and generate intermediate variable files

    Options
        -m manifest_dir -- Location of manifest files that describe the deployment.
            Requires: install-config.yaml, bootstrap.yaml, master-0.yaml, [masters/workers...]
            Defaults to $PROJECT_DIR/cluster/
        -o out_dir -- Where to put the output [defaults to $DNSMASQ_DIR...]
EOM
    exit 0
}

# [ostype]="kernel_path:initrd_path"
declare -A OSType=(
    [rhel8]="assets/rhel8/images/pxeboot/vmlinuz:assets/rhel8/images/pxeboot/initrd.img"
    [rhcos]="assets/rhcos-4.1.0-x86_64-installer-kernel:assets/rhcos-4.1.0-x86_64-installer-initramfs.img"
)

gen_settings_env() {
    ofile="$1"

    if [ -f "$ofile" ]; then
        update_settings_env "$ofile"
    else
        create_settings_env "$ofile"
    fi
}

create_settings_env() {
    ofile="$1"

    {

        printf "export CLUSTER_NAME=\"%s\"\n" "${MANIFEST_VALS[install\-config.metadata.name]}"
        printf "export BASE_DOMAIN=\"%s\"\n" "${MANIFEST_VALS[install\-config.baseDomain]}"
        printf "export PULL_SECRET=\"%s\"\n" "${MANIFEST_VALS[install\-config.pullSecret]}"
        printf "export KUBECONFIG_PATH=\"%s\"\n" "$PROJECT_DIR/ocp/auth/kubeconfig"
        printf "export ROOT_PASSWORD=\"\"\n"
        printf "export RH_USERNAME=\"\"\n"
        printf "export RH_PASSWORD=\"\"\n"
        printf "export RH_POOL=\"\"\n"
        printf "export RHEL_INSTALL_ENDPOINT=\"%s\"\n" "$PROV_IP_MATCHBOX_HTTP_URL/assets/rhel8"
        printf "# i.e. 1:4-10-12\n"
        printf "export RT_TUNED_ISOLATE_CORES=\"\"\n"
        printf "export RT_TUNED_HUGEPAGE_SIZE_DEFAULT=\"2G\"\n"
        printf "export RT_TUNED_HUGEPAGE_SIZE=\"2G\"\n"
        printf "export RT_TUNED_HUGEPAGE_NUM=\"2\"\n"

    } >"$ofile"
}

update_settings_env() {
    ofile="$1"

    sed -i -re "s/.*CLUSTER_NAME.*/export CLUSTER_NAME=\"${MANIFEST_VALS[install\-config.metadata.name]}\"/" "$ofile"
    sed -i -re "s/.*BASE_DOMAIN.*/export BASE_DOMAIN=\"${MANIFEST_VALS[install\-config.baseDomain]}\"/" "$ofile"
    sed -i -re "s/.*PULL_SECRET.*/export PULL_SECRET=\"${MANIFEST_VALS[install\-config.pullSecret]}\"/" "$ofile"
    sed -i -re "s|.*KUBECONFIG_PATH.*|export KUBECONFIG_PATH=\"$PROJECT_DIR/ocp/auth/kubeconfig\"|" "$ofile"
    sed -i -re "s|.*RHEL_INSTALL_ENDPOINT.*|export RHEL_INSTALL_ENDPOINT=\"$PROV_IP_MATCHBOX_HTTP_URL/assets/rhel8\"|" "$ofile"
}

create_kickstart() {
    ks_config="$1"
    ks_script="$2"

    if ! ks=$(cat "$ks_script"); then
        printf "Missing file: %s!\n" "$ks_config"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$ks_config"

    ks=$(echo "$ks" | sed -re "s|.*settings_upi.env$||")

    ks=$(echo "$ks" | sed -re "s|^CORE_SSH_KEY.*|CORE_SSH_KEY=\"${MANIFEST_VALS[install\-config.sshKey]}\"|")

    (
        cd "$UPI_RT_DIR/kickstart" || return 1

        eval "$ks"

        mv rhel8-worker-kickstart.cfg "$BUILD_DIR"
    )

    cp "$BUILD_DIR/rhel8-worker-kickstart.cfg" "$MATCHBOX_DATA_DIR/var/lib/matchbox/assets"
}

VERBOSE="false"
export VERBOSE

while getopts ":hvm:" opt; do
    case ${opt} in
    v)
        VERBOSE="true"
        ;;
    m)
        manifest_dir=$OPTARG
        ;;
    h)
        usage
        exit 0
        ;;
    \?)
        echo "Invalid Option: -$OPTARG" 1>&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -gt 0 ]; then
    COMMAND=$1
    shift
else
    COMMAND="create"
fi
# shellcheck disable=SC1091
source "common.sh"

# shellcheck disable=SC1090
source "$PROJECT_DIR/scripts/cluster_map.sh"

# shellcheck disable=SC1090
source "$PROJECT_DIR/scripts/utils.sh"
# shellcheck disable=SC1090
source "$PROJECT_DIR/scripts/paths.sh"

manifest_dir=${manifest_dir:-$MANIFEST_DIR}
manifest_dir=$(realpath "$manifest_dir")

prep_host_setup_src=$(realpath "$manifest_dir/prep_bm_host.src")

# get prep_host_setup.src file info
parse_prep_bm_host_src "$prep_host_setup_src"

# shellcheck disable=SC1090
source "$PROJECT_DIR/scripts/network_conf.sh"

parse_manifests "$manifest_dir"

case "$COMMAND" in
create)
    create_settings_env "$PROJECT_DIR/$SETTINGS_FILE"
    ;;
update)
    gen_settings_env "$PROJECT_DIR/$SETTINGS_FILE"
    ;;
kickstart)
    gen_settings_env "$PROJECT_DIR/$SETTINGS_FILE"
    
    if ! create_kickstart "$PROJECT_DIR/$SETTINGS_FILE" "$UPI_RT_DIR/kickstart/add_kickstart_for_rhel8.sh"; then
        printf "Creation of kickstart failed!"
    fi
    ;;
*)
    echo "Unknown command: ${COMMAND}"
    usage
    ;;
esac
