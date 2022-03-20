#!/usr/bin/env bash

shopt -s nullglob
set -e

if [ "$1" == "all" ]; then
    repos="termux-packages termux-root-packages x11-packages"
else
    repos="$1"
fi

: "${TMPDIR:=/tmp}"

# TERMUX_TOPDIR is defined in termux_step_setup_variables
source ./termux-packages/termux-packages/scripts/build/termux_step_setup_variables.sh
source ./termux-packages/termux-packages/scripts/build/termux_extract_dep_info.sh
export TERMUX_SCRIPTDIR=./termux-packages/termux-packages
source $TERMUX_SCRIPTDIR/scripts/properties.sh
termux_step_setup_variables

download_deb() {
    # This function sources a package's build.sh, and possible *.subpackage.sh,
    # and downloads the debs from a given repo. Debs are saved in $TERMUX_TOPDIR/_cache-$ARCH,
    # which is the same directory as when doing ./build-package.sh -i <pkg> builds
    pkg=$1
    pkg_dir=$2
    packages_file=$3
    TERMUX_ARCH=$4

    TERMUX_SCRIPTDIR=.

    for build_file in ${pkg_dir}/build.sh ${pkg_dir}/*.subpackage.sh; do
        if [ "$(basename $build_file)" == "build.sh" ]; then
            pkg_name=$pkg
        else
            pkg_name=$(basename ${build_file%%.*})
        fi

        dep_arch=""
        dep_version=""
        # Some packages, like all of texlive's subpackages, gives an error when sourcing the build.sh.
        # This happens because texlive's subpackages use a script to get the file list, which fails due
        # to unset variables in this context. We are only interested in the arch, not the file list
        # though so this error is not blocking. stderr is redirected to /dev/null below until a nicer
        # workaround can be found.

        read dep_arch dep_version ignore <<< $(termux_extract_dep_info $pkg_name "${pkg_dir}" 2>/dev/null)
        if [ -z "$dep_arch" ]; then
            # termux_extract_dep_info returned nothing so the package
            # is probably blacklisted for the current arch
            return
        fi

        (
            cd "$TERMUX_TOPDIR/_cache-${dep_arch}"
            if [ ! -f "${pkg_name}_${dep_version}_${dep_arch}.deb" ]; then
                # Get path to the deb on the repo
                deb_path=$(get_deb_path ${packages_file} $pkg_name $dep_version $dep_arch)
                if [ -z "$deb_path" ]; then
                    printf "%-50s \e[31m%s\e[0m\n" "${pkg_name}_${dep_version}_${dep_arch}.deb" "not found in repo" 1>&2
                    return
                fi
                echo "Downloading ${repo_url}/${deb_path}" 1>&2
                temp_deb=$(mktemp $TMPDIR/$(basename ${deb_path}).XXXXXX)
                curl --fail -L -o "${temp_deb}" "${repo_url}/${deb_path}" || \
                    echo "Download of ${repo_url}/${deb_path} failed" 1>&2
                mv ${temp_deb} $(basename ${deb_path})
            else
                printf "%-50s %s\n" "${pkg_name}_${dep_version}_${dep_arch}.deb" "already downloaded" 1>&2
            fi
            echo "$TERMUX_TOPDIR/_cache-${dep_arch}/${pkg_name}_${dep_version}_${dep_arch}.deb\n"
        )
    done
}

get_deb_path() {
    packages_file=$1
    pkg=$2
    version=$3
    arch=$4

    # Get lines between "Package: $package" and the next empty
    # line (marking start of next Package: entry).
    deb_paths=$(sed -n "/Package: $(basename $pkg)$/,/^$/p" \
        ${packages_file} | grep Filename | awk '{print $2}')

    # Check for correct entry in $deb_paths with correct version
    # in case several entries were found.
    for path in $deb_paths; do
        if [ "$(basename $path)" == "${pkg}_${version}_${arch}.deb" ]; then
            echo $path
        fi
    done
}

for repo in $repos; do
    case $repo in
        termux-packages)
            repo_url="https://packages-cf.termux.org/apt/termux-main"
            distribution="stable"
            component="main"
            ;;
        termux-root-packages)
            repo_url="https://packages-cf.termux.org/apt/termux-root"
            distribution="root"
            component="stable"
            ;;
        x11-packages)
            repo_url="https://packages-cf.termux.org/apt/termux-x11"
            distribution="x11"
            component="main"
            ;;
        *)
            echo "Unknown repo: '$repo'"
            exit 1
    esac

    for arch in aarch64 arm i686 x86_64; do
        # Get current commit, based on files checked into git
        current_commit=$(basename $(git ls-files $repo/commands-${arch}-*.h) \
                             |awk -F"-" '{ print substr($3,1,7) }')

        # Get new commit (current checked out commit of submodule)
        new_commit=$(git submodule status $repo \
                         |awk '{ if ($1 ~ /^+/) {print substr($1,2,7)} else {print substr($1,1,7)} }')
        if [ "$current_commit" == "$new_commit" ]; then continue; fi

        mkdir -p "$TERMUX_TOPDIR/_cache-${arch}"
        # Let's get Packages file for $arch so that we can parse it to get
        # path on repo to the deb we want to download.
        temp_packages=$(mktemp $TMPDIR/Packages_$arch.XXXXXX)
        curl --fail -L -o "${temp_packages}" "${repo_url}/dists/$distribution/$component/binary-$arch/Packages" || \
            echo "Download of ${repo_url}/dists/$distribution/$component/binary-$arch/Packages failed" 1>&2 || exit 1
        packages_file="$TERMUX_TOPDIR/_cache-${arch}/$(echo ${repo_url}|sed -e "s@https://@@g" -e "s@/@-@g")-$distribution-$component-binary-$arch-Packages"
        mv ${temp_packages} "$packages_file"

        pushd $repo/$repo
        changed_files=$(git diff --name-status -C ${current_commit} ${new_commit} \
                            -- packages | cut -f 2-)

        deleted_packages=""
        updated_packages=""
        for file in ${changed_files}; do
            if [[ "$file" == "*.subpackage.sh" ]]; then
                if [ ! -f "$file" ] && ! grep "^TERMUX_PKG_BLACKLISTED_ARCHES=.*$arch.*" "$(echo $file|cut -d/ -f 1-2)/build.sh">/dev/null; then
                    # Subpackage seem to have been deleted,
                    # we need to delete it from the command list
                    deleted_packages+=" $(basename $file|sed "s@.subpackage.sh@@g")"
                else
                    # ut to only get first two levels of the path
                    # (packages/foo).  with dirname we run into issues
                    # with packages that have subfolders in
                    # packages/foo/.
                    updated_packages+=" $(echo $file | cut -d/ -f 1-2)"
                fi
            elif [ -d "$(dirname $file)" ] && ! grep "^TERMUX_PKG_BLACKLISTED_ARCHES=.*$arch.*" "$(echo $file|cut -d/ -f 1-2)/build.sh">/dev/null; then
                updated_packages+=" $(echo $file | cut -d/ -f 1-2)"
            else
                # Package seem to have been deleted,
                # we need to delete it from the command list
                deleted_packages+=" $(echo $file | cut -d/ -f 1-2)"
            fi
        done

        debs=""
        updated_packages="$(echo $updated_packages | xargs -n 1 | sort | uniq)"
        # echo "Updated $updated_packages" > /dev/stderr
        for package in ${updated_packages}; do
            if [ -d $package ] && ! grep "^TERMUX_PKG_BLACKLISTED_ARCHES=.*$arch.*" "$(echo $file | cut -d/ -f 1-2)/build.sh">/dev/null; then
                debs+="$(download_deb $(basename $package) $package ${packages_file} $arch)"
            else
                # Package seem to have been deleted,
                # we need to delete it from the command list
                deleted_packages+=" $package"
            fi
        done

        deleted_packages=$(echo $deleted_packages | xargs -n 1 | sort | uniq)
        echo "Deleted $deleted_packages" > /dev/stderr
        if [ ! "$deleted_packages" == "" ]; then
            extra_args="--delete $deleted_packages"
        fi

        popd

        # Length of $DEBS could be larger than ARG_MAX, at least on some
        # systems. To not risk such a problem we pipe the DEB list instead of
        # giving it as an argument.
        echo -e "$debs" | ./modify_command_list.py "./${repo}/commands-${arch}-${current_commit}.h" ${new_commit} ${extra_args}
        sed -i "s%# include \"${repo}/commands-${arch}-.*.h\"%# include \"${repo}/commands-${arch}-${new_commit}\.h\"%g" command-not-found.cpp
    done
done
