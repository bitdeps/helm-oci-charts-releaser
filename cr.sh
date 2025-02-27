#!/usr/bin/env bash

# Copyright The Helm Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

DEFAULT_HELM_VERSION=v3.13.2
ARCH=$(uname)
ARCH="${ARCH,,}-amd64" # Official helm is available only for x86_64

released_charts=()
dry_run="${DRY_RUN:-false}"

show_help() {
  cat <<EOF
Usage: $(basename "$0") <options>

    -h, --help                    Display help
    -v, --version                 The helm version to use (default: $DEFAULT_HELM_VERSION)"
    -d, --charts-dir              The charts directory (default either: helm, chart or charts)
    -u, --oci-username            The username used to login to the OCI registry
    -r, --oci-registry            The OCI registry
    -p, --oci-path                The OCI path to construct full path as {{oci-registry}}/{{oci-path}}
    -t, --tag-name-pattern        Specifies GitHub repository release naming pattern (ex. '{chartName}-chart')
        --install-dir             Specifies custom install dir
        --skip-helm-install       Skip helm installation (default: false)
        --skip-dependencies       Skip dependencies update from "Chart.yaml" to dir "charts/" before packaging (default: false)
        --skip-existing           Skip the chart push if the GitHub release exists
        --skip-oci-login          Skip the OCI registry login (default: false)
    -l, --mark-as-latest          Mark the created GitHub release as 'latest' (default: true)
        --skip-gh-release         Skip the GitHub release creation
EOF
}

errexit() {
  >&2 echo "$*"
  exit 1
}

main() {
  local version="$DEFAULT_HELM_VERSION"
  local charts_dir=
  local oci_username=
  local oci_registry=
  local oci_host=
  local install_dir=
  local skip_helm_install=false
  local skip_dependencies=false
  local skip_existing=true
  local skip_oci_login=false
  local mark_as_latest=true
  local tag_name_pattern=
  local skip_gh_release
  local repo_root=

  parse_command_line "$@"

  : "${GITHUB_TOKEN:?Environment variable GITHUB_TOKEN must be set}"
  if ( ! $skip_oci_login ) then
    : "${OCI_PASSWORD:?Environment variable OCI_PASSWORD must be set unless you skip oci login.}"
  fi

  (! $dry_run) || echo "===> DRY-RUN: TRUE"

  repo_root=$(git rev-parse --show-toplevel)
  pushd "$repo_root" >/dev/null

  find_charts_dir
  echo 'Looking up latest tag...'

  local latest_tag
  latest_tag=$(lookup_latest_tag)

  echo "Discovering changed charts since '$latest_tag'..."
  local changed_charts=()
  readarray -t changed_charts <<<"$(lookup_changed_charts "$latest_tag")"

  if [[ -n "${changed_charts[*]}" ]]; then
    install_helm
    helm_login

    for chart in "${changed_charts[@]}"; do
      local desc name version info=()
      readarray -t info <<<"$(chart_info "$chart")"
      desc="${info[0]}"
      name="${info[1]}"
      version="${info[2]}"

      package_chart "$chart"
      release_chart "$chart" "$name" "$version" "$desc"
    done

    echo "released_charts=$(
      IFS=,
      echo "${released_charts[*]}"
    )" >released_charts.txt
  else
    echo "Nothing to do. No chart changes detected."
    echo "released_charts=" >released_charts.txt
  fi

  echo "chart_version=${latest_tag}" >chart_version.txt
  popd >/dev/null
}

parse_command_line() {
  while [ "${1:-}" != "-" ]; do
    case "${1:-}" in
    -h | --help)
      show_help
      exit
      ;;
    -v | --version)
      if [[ -n "${2:-}" ]]; then
        version="$2"
        shift
      else
        echo "ERROR: '-v|--version' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -d | --charts-dir)
      if [[ -n "${2:-}" ]]; then
        charts_dir="$2"
        shift
      else
        echo "ERROR: '-d|--charts-dir' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -u | --oci-username)
      if [[ -n "${2:-}" ]]; then
        oci_username="$2"
        shift
      else
        echo "ERROR: '--oci-username' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    -r | --oci-registry)
      if [[ -n "${2:-}" ]]; then
        oci_registry="$2"
        shift
      else
        echo "ERROR: '--oci-registry' cannot be empty." >&2
        show_help
        exit 1
      fi
      ;;
    --install-dir)
      if [[ -n "${2:-}" ]]; then
        install_dir="$2"
        shift
      fi
      ;;
    --skip-helm-install)
      if [[ -n "${2:-}" ]]; then
        skip_helm_install="$2"
        shift
      fi
      ;;
    --skip-dependencies)
      if [[ -n "${2:-}" ]]; then
        skip_dependencies="$2"
        shift
      fi
      ;;
    --skip-existing)
      if [[ -n "${2:-}" ]]; then
        skip_existing="$2"
        shift
      fi
      ;;
    --skip-oci-login)
      if [ "${2}" == "true" ]; then
        skip_oci_login=true
        shift
      fi
      ;;
    -l | --mark-as-latest)
      if [[ -n "${2:-}" ]]; then
        mark_as_latest="$2"
        shift
      fi
      ;;
    -t | --tag-name-pattern)
      if [[ -n "${2:-}" ]]; then
        tag_name_pattern="$2"
        shift
      fi
      ;;
    --skip-gh-release)
      if [[ -n "${2:-}" ]]; then
        skip_gh_release="$2"
        shift
      fi
      ;;
    *)
      break
      ;;
    esac

    shift
  done

  if ( ! $skip_oci_login ) then
    if [[ -z "$oci_username"  ]]; then
      echo "ERROR: '-u|--oci-username' is required unless you skip oci login." >&2
      show_help
      exit 1
    fi
  fi

  if [[ -z "$oci_registry" ]]; then
    echo "ERROR: '-r|--oci-registry' is required." >&2
    show_help
    exit 1
  fi

  if [[ -n $tag_name_pattern && $tag_name_pattern != *"{chartName}"* ]]; then
    echo "ERROR: Name pattern must contain '{chartName}' field." >&2
    show_help
    exit 1
  fi

  if [[ -z "$install_dir" ]]; then
    # use /tmp or RUNNER_TOOL_CACHE in GitHub Actions
    install_dir="${RUNNER_TOOL_CACHE:-/tmp}/cra/$ARCH"

    export HELM_CACHE_HOME="${install_dir}/.cache"
    export HELM_CONFIG_HOME="${install_dir}/.config"
    export HELM_DATA_HOME="${install_dir}.share"
  fi
}

install_helm() {
  if ( "$skip_helm_install" ) && ( which helm &> /dev/null ); then
    echo "Skipng helm install. Using existing helm..."
    return
  elif ( "$skip_helm_install" ); then
    errexit "ERROR: Remove --skip-helm-install or preinstall!"
  fi

  if [[ ! -x "$install_dir/helm" ]]; then
    mkdir -p "$install_dir"

    echo "Installing Helm ($version) to $install_dir..."
    curl -sSLo helm.tar.gz "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz"
    curl -sSL "https://get.helm.sh/helm-${version}-${ARCH}.tar.gz.sha256sum" | \
      sed 's/helm-.*/helm.tar.gz/' > helm.sha256sum

    if ( ! sha256sum -c helm.sha256sum ); then
      rm -f helm.tar.gz helm.sha256sum
      errexit "ERROR: Aborting helm checksum is invalid"
    fi

    tar -C "$install_dir/.." -xzf helm.tar.gz "$ARCH/helm"
    rm -f helm.tar.gz helm.sha256sum
  else
    echo "Helm is found in the install directory"
  fi

  echo 'Setting PATH to use helm from the install directory...'
  export PATH="$install_dir:$PATH"
}

lookup_latest_tag() {
  git fetch --tags >/dev/null 2>&1

  if ! git describe --tags --abbrev=0 HEAD~ 2>/dev/null; then
    git rev-list --max-parents=0 --first-parent HEAD
  fi
}

filter_charts() {
  local charts=()
  while read -r path; do
    if [[ -f "${path}/Chart.yaml" ]]; then
      charts+=("$path")
    fi
  done
  printf "%s\n" "${charts[@]}"
}

find_charts_dir() {
  local cdirs=()
  if [ -n "$charts_dir" ]; then return; fi
  if [ -f "helm/Chart.yaml" ]; then cdirs+=("."); fi
  if [ -f "chart/Chart.yaml" ]; then cdirs+=("."); fi
  if (( "${#cdirs[@]}" > 1 )); then
    errexit "ERROR: Can't use both helm and chart directory."
  fi
  charts_dir="${cdirs[0]:-charts/}"
}

lookup_changed_charts() {
  local commit="$1"

  local changed_files
  changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")

  local depth=$(($(tr "/" "\n" <<<"$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1))
  local fields="1-${depth}"

  cut -d '/' -f "$fields" <<<"$changed_files" | uniq | filter_charts
}

package_chart() {
  local chart="$1" flags=
  ( $skip_dependencies ) || flags="-u"

  echo "Packaging chart '$chart'..."
  dry_run helm package "$chart" $flags -d "${install_dir}/package/$chart"
}

dry_run() {
  # dry-run on
  if ($dry_run); then
    { set -x; echo "$@" >/dev/null; set +x; } 2>&1 | sed '/set +x/d' >&2; return
  else
    "$@"
  fi
}

chart_info() {
  local chart_dir="$1"
  # use readarray with the returned line
  helm show chart "$chart_dir" | sed -En '/^(description|name|version)/p' | sort | sed 's/^.*: //'
}

# get github release tag
release_tag() {
  local name="$1" version="$2"
  if [ -n "$tag_name_pattern" ]; then
    tag="${tag_name_pattern//\{chartName\}/$name}"
  fi
  echo "${tag:-$name}-$version"
}

release_exists() {
  local tag="$1"
  # fields: release tagName date
  dry_run gh release ls | tr -s '[:blank:]' | sed -E 's/\sLatest//' | cut -f 1 | grep -q "$tag" && echo true || echo false
}

release_chart() {
  local releaseExists flags tag chart_package chart="$1" name="$2" version="$3" desc="$4"
  tag=$(release_tag "$name" "$version")
  chart_package="${install_dir}/package/${chart}/${name}-${version}.tgz"
  releaseExists=$(release_exists "$tag")

  if ($releaseExists && $skip_existing); then
    echo "Release tag '$tag' is present. Skip chart push (skip_existing=true)..."
    return
  fi

  dry_run helm push "${chart_package}" "oci://${oci_registry#oci://}"

  if (! $releaseExists && ! $skip_gh_release); then
    # shellcheck disable=SC2086
    (! $mark_as_latest) || flags="--latest"
    dry_run gh release create "$tag" $flags --title "$tag" --notes "$desc"
  fi

  # (re)upload package, i.e. overwrite, since skip_existing is not provided.
  if (! $skip_gh_release); then
    dry_run gh release upload "$tag" "$chart_package" --clobber
    released_charts+=("$chart")
  fi
}

helm_login() {
  if ( $skip_oci_login ) then
    echo "Skipping helm login. Using existing credentials..."
    return
  fi
  # Get the cleared host url
  oci_registry="${oci_registry#oci://}"
  oci_host="${oci_registry%%/*}"
  echo "$OCI_PASSWORD" | dry_run helm registry login -u "${oci_username}" --password-stdin "${oci_host}"
}

main "$@"
