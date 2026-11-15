#!/bin/bash

# autopatch.sh: script to manage patches on top of repo
# Copyright (C) 2019 Intel Corporation. All rights reserved.
# Author: sgnanase <sundar.gnanasekaran@intel.com>
# Author: Sun, Yi J <yi.j.sun@intel.com>
#
# SPDX-License-Identifier: BSD-3-Clause

top_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd) || exit 1
if [[ ! -d "$top_dir/.repo" || -z "${TARGET_PRODUCT:-}" ]]; then
    echo "[autopatch.sh] Run inside a repo checkout with TARGET_PRODUCT set." >&2
    exit 1
fi
# Patch directories are keyed by BSP family, which may differ from product name.
if [[ -n "${AUTOPATCH_PATCH_TARGET:-}" ]]; then
    TARGET_PRODUCT="$AUTOPATCH_PATCH_TARGET"
fi
utils_dir="$top_dir/vendor/intel/utils"
patch_dir_aosp="$utils_dir/aosp_diff"
patch_dir_bsp="$utils_dir/bsp_diff"
private_utils_dir="$top_dir/vendor/intel/utils_priv"
private_patch_dir_aosp="$private_utils_dir/aosp_diff"
private_patch_dir_bsp="$private_utils_dir/bsp_diff"
vertical_utils_dir="$top_dir/vendor/intel/utils_vertical"
vertical_patch_dir_aosp="$vertical_utils_dir/aosp_diff"
vertical_patch_dir_bsp="$vertical_utils_dir/bsp_diff"
private_vertical_utils_dir="$top_dir/vendor/intel/utils_vertical_priv"
private_vertical_patch_dir_aosp="$private_vertical_utils_dir/aosp_diff"
private_vertical_patch_dir_bsp="$private_vertical_utils_dir/bsp_diff"

current_project=""
previous_project=""
conflict=""
conflict_list=""
applied_already=""
git_select=""

usage() {
	echo "USAGE"
	echo "Run below cmd to apply patches only to a specific repo:"
	echo "$ TARGET_PRODUCT=<name> vendor/intel/utils/autopatch.sh <repo name>"
	echo "OR just run to apply patches to all repos"
	echo "$ TARGET_PRODUCT=<name> vendor/intel/utils/autopatch.sh"
}

# Dates are a search hint, never proof that a patch is already applied.
# Receipts live outside the generated source files and remain valid only
# while their verified commit is an ancestor of the current HEAD.
declare -A history_files index_files
scratch_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$scratch_dir"' EXIT
log_dir="${OUT_DIR:-$top_dir/out}/autopatch"
[[ "$log_dir" = /* ]] || log_dir="$top_dir/$log_dir"
mkdir -p "$log_dir" || exit 1
log_file="$log_dir/$(date +%Y%m%d-%H%M%S)-$$.log"
touch "$log_file" || exit 1
echo "[autopatch.sh] Git patch log: $log_file"

patch_failure() {
    echo "[autopatch.sh] $*" | tee -a "$log_file" >&2
    echo "[autopatch.sh] See $log_file; configuration generation has been stopped." >&2
    echo '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")' > "$vertical_utils_dir/Android.mk"
    exit 1
}

patch_id() {
    git patch-id --stable | awk 'NR == 1 {print $1}'
}

commit_matches_patch() {
    local commit=$1 patch=$2 expected_hash=$3 candidate_hash applied_tree expected_tree change_id
    candidate_hash=$(git show --format= --no-ext-diff --binary --full-index "$commit" | patch_id)
    [[ "$candidate_hash" = "$expected_hash" ]] && return 0

    # Gerrit backports can be manually adapted rather than mechanically
    # replayable. Their Change-Id identifies the already integrated change.
    while read -r change_id; do
        if git show -s --format=%B "$commit" | grep -Fxq "$change_id"; then
            return 0
        fi
    done < <(sed -n '/^diff --git /q; /^Change-Id: I[0-9a-f]\{40\}$/p' "$patch")

    # Some backports only move identical additions/deletions to new context.
    # Require the same subject and author as well as exact changed lines.
    if python3 "$vertical_utils_dir/patch_identity.py" "$patch" "$commit"; then
        return 0
    fi

    # A previous git am -3 may have adapted the diff to this branch. Replay
    # against that commit's parent in an isolated index and compare full trees.
    # This recognizes the adaptation without trusting its author date alone.
    local replay_index="$scratch_dir/replay-index"
    rm -f "$replay_index"
    GIT_INDEX_FILE="$replay_index" git read-tree "$commit^" 2>/dev/null || return 1
    GIT_INDEX_FILE="$replay_index" git apply --cached --3way "$patch" >/dev/null 2>&1 || return 1
    applied_tree=$(GIT_INDEX_FILE="$replay_index" git write-tree) || return 1
    expected_tree=$(git rev-parse "$commit^{tree}") || return 1
    [[ "$applied_tree" = "$expected_tree" ]]
}

already_applied() {
    local patch=$1 repo=$2 receipt=$3 original patch_hash patch_date timestamp candidate
    local verified_commit
    if [[ -f "$receipt" ]]; then
        read -r verified_commit < "$receipt"
        if [[ -n "$verified_commit" ]] && git merge-base --is-ancestor "$verified_commit" HEAD 2>/dev/null; then
            return 0
        fi
    fi

    patch_hash=$(patch_id < "$patch")
    [[ -n "$patch_hash" ]] || return 1
    original=$(sed -n '1s/^From \([0-9a-f]\{40\}\) .*/\1/p' "$patch")
    if [[ -n "$original" ]] && git merge-base --is-ancestor "$original" HEAD 2>/dev/null &&
        commit_matches_patch "$original" "$patch" "$patch_hash"; then
        return 0
    fi
    if [[ -z "${history_files[$repo]:-}" ]]; then
        history_files[$repo]=$(mktemp "$scratch_dir/history.XXXXXX")
        git log -500 --no-merges --format='%H %at' > "${history_files[$repo]}" || return 1
    fi
    patch_date=$(sed -n 's/^Date: //p' "$patch" | head -1)
    timestamp=$(date -d "$patch_date" +%s 2>/dev/null) || timestamp=""
    if [[ -n "$timestamp" ]]; then
        while read -r candidate; do
            commit_matches_patch "$candidate" "$patch" "$patch_hash" && return 0
        done < <(awk -v date="$timestamp" '$2 == date {print $1}' "${history_files[$repo]}")
    fi

    # Inspect HEAD through a temporary index, not local edits or mixin output.
    if [[ -z "${index_files[$repo]:-}" ]]; then
        index_files[$repo]=$(mktemp "$scratch_dir/index.XXXXXX")
        rm -f "${index_files[$repo]}"
        GIT_INDEX_FILE="${index_files[$repo]}" git read-tree HEAD || return 1
    fi
    GIT_INDEX_FILE="${index_files[$repo]}" git apply --cached --reverse --check "$patch" 2>/dev/null
}

record_applied() {
    local receipt=$1
    mkdir -p "$(dirname "$receipt")" && git rev-parse HEAD > "$receipt"
}

clear_conflict_marker() {
    local marker=$1
    if [[ -f "$marker" ]] && cmp -s "$marker" <(printf '%s\n' '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")'); then
        rm -f "$marker"
    fi
}

apply_patch() {
    local pl=$1 pd=$2 i repo git_dir receipt checksum
    for i in $pl; do
        current_project=$(dirname "$i")
        if [[ "$current_project" != "$previous_project" ]]; then
            echo ""
            echo "Project $current_project"
        fi
        previous_project=$current_project

        cd "$top_dir/$current_project" || patch_failure "Missing project: $current_project"
        repo=$(git rev-parse --show-toplevel) || patch_failure "Not a Git project: $current_project"
        cd "$repo" || exit 1
        git_dir=$(git rev-parse --absolute-git-dir) || exit 1
        if [[ -d "$(git rev-parse --git-path rebase-apply)" || -d "$(git rev-parse --git-path rebase-merge)" ]]; then
            patch_failure "Finish the existing am/rebase operation in $current_project first."
        fi
        checksum=$(sha256sum "$pd/$i")
        receipt="$git_dir/celadon-autopatch/${checksum%% *}"

        if already_applied "$pd/$i" "$repo" "$receipt"; then
            echo -e "\tAlready applied\t\t$(basename "$i")"
            applied_already="y"
            record_applied "$receipt" || patch_failure "Cannot record patch receipt: $current_project"
            continue
        fi

        # New patches must not risk unrelated local edits. Existing patches
        # above can safely be skipped even when the working tree is modified.
        if ! git diff --quiet || ! git diff --cached --quiet; then
            patch_failure "Uncommitted changes in $current_project; cannot apply $(basename "$i"). Back up/commit the changes first."
        fi
        printf '\nProject: %s\nPatch: %s\n' "$current_project" "$pd/$i" >> "$log_file"
        if git am -3 --keep-cr --whitespace=nowarn "$pd/$i" >> "$log_file" 2>&1; then
            echo -e "\tApplying\t\t$(basename "$i")"
            record_applied "$receipt" || patch_failure "Cannot record patch receipt: $current_project"
            unset 'history_files[$repo]' 'index_files[$repo]'
        else
            tail -n 40 "$log_file" >&2
            if [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
                git am --abort >> "$log_file" 2>&1 || patch_failure "Could not abort failed patch in $current_project"
            fi
            patch_failure "Patch failed in $current_project: $(basename "$i")"
        fi
    done
}

function fpnat() # find patch files and apply them
{
    local patch_top_dir=$1
    # arg #1 should be the .patch files' top directory,
    # either aosp_diff/preliminary or aosp_diff/${TARGET_PRODUCT}
    # and bsp_diff/preliminary bsp_diff/${TARGET_PRODUCT} directories.
    cd "${patch_top_dir}" || patch_failure "Missing patch directory: $patch_top_dir"
    patch_file_number=`find ./$git_select -iname "*.patch" 2>/dev/null |wc -l`
    echo "Path: `basename ${patch_top_dir}` has ${patch_file_number} patch file(s) to apply!"
    if [[ ${patch_file_number} != 0 ]];then
        patch_list=`find ./$git_select -iname "*.patch" 2>/dev/null | sort -u`
        apply_patch "${patch_list}" "${patch_top_dir}"
        if [[ $? != 0 ]]; then
            echo "Apply ${patch_top_dir} patches failure!"
        fi
    fi
    unset patch_list patch_top_dir
}

if [[ $# -eq 1 ]]; then
	if [[ -d $top_dir/$1 ]]; then
		git_select="$1"
	else
		echo "$1 - this git doesn't exist"
		usage
		exit -1
	fi
fi

if [[ $# -gt 1 || $# -lt 0 ]]; then
	usage
	exit -1
fi

if [[ -e ${patch_dir_aosp}/${TARGET_PRODUCT}/include_preliminary ]] || [[ -e ${private_patch_dir_aosp}/${TARGET_PRODUCT}/include_preliminary ]];then
    echo -e "\nApply utils/aosp_diff/preliminary patches:"
    fpnat "$patch_dir_aosp/preliminary"
fi

if [[ -e ${patch_dir_aosp}/${TARGET_PRODUCT} ]] && [[ -d ${patch_dir_aosp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils/aosp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${patch_dir_aosp}/${TARGET_PRODUCT}"
fi

if [[ -e ${patch_dir_bsp}/${TARGET_PRODUCT}/include_common ]] || [[ -e ${private_patch_dir_bsp}/${TARGET_PRODUCT}/include_common ]];then
    echo -e "\nApply utils/bsp_diff/common Patches:"
    fpnat "${patch_dir_bsp}/common"
fi

if [[ -e ${patch_dir_bsp}/${TARGET_PRODUCT} ]] && [[ -d ${patch_dir_bsp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils/bsp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${patch_dir_bsp}/${TARGET_PRODUCT}"
fi

if [[ "$conflict" == "y" ]]; then
  echo -e "\n\n\t\tALERT : Conflicts Observed while patch application !!           "
  for i in $conflict_list ; do echo $i; done | sort -u
  echo -e "\n\n\t\tError: Please resolve Conflict(s) and re-run lunch..."
  echo '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")' > $top_dir/vendor/intel/utils/Android.mk
else
  echo -e "\n\t\tSUCCESS : All patches applied successfully in: `basename $patch_dir_aosp` and `basename ${patch_dir_bsp}` !!"
  if [[ "$applied_already" == "y" ]]; then
    echo -e "\n\t\tINFO : SOME PATCHES ARE APPLIED ALREADY  !!"
  fi
  clear_conflict_marker "$top_dir/vendor/intel/utils/Android.mk"
fi

# Apply Embargoed patches if exist
if [[ -e ${private_utils_dir} ]] && [[ -d ${private_utils_dir} ]];then
        echo -e "\n============================="
        echo "Embargoed Patches Found"
        echo "============================="

    if [[ -e ${private_patch_dir_aosp}/${TARGET_PRODUCT}/include_preliminary_priv ]];then
        echo -e "\nApply utils_priv/aosp_diff/preliminary Patches:"
        fpnat "${private_patch_dir_aosp}/preliminary"
    fi

    if [[ -e ${private_patch_dir_aosp}/${TARGET_PRODUCT} ]] && [[ -d ${private_patch_dir_aosp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils_priv/aosp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${private_patch_dir_aosp}/${TARGET_PRODUCT}"
    fi

    if [[ -e ${private_patch_dir_bsp}/${TARGET_PRODUCT}/include_common_priv ]];then
        echo -e "\nApply utils_priv/bsp_diff/common Patches:"
        fpnat "${private_patch_dir_bsp}/common"
    fi

    if [[ -e ${private_patch_dir_bsp}/${TARGET_PRODUCT} ]] && [[ -d ${private_patch_dir_bsp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils_priv/bsp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${private_patch_dir_bsp}/${TARGET_PRODUCT}"
    fi

    if [[ "$conflict" == "y" ]]; then
      echo -e "\n\t\tALERT : Conflicts Observed while patch application !!           "
      for i in $conflict_list ; do echo $i; done | sort -u
      echo -e "\n\t\tError: Please resolve Conflict(s) and re-run lunch..."
      echo '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")' > $top_dir/vendor/intel/utils_priv/Android.mk
    else
      echo -e "\n\t\tSUCCESS : All patches applied SUCCESSFULLY in `basename ${private_patch_dir_aosp}` and `basename ${private_patch_dir_bsp}`"
      if [[ "$applied_already" == "y" ]]; then
        echo -e "\n\t\tINFO : SOME PATCHES ARE APPLIED ALREADY  !!"
      fi
      clear_conflict_marker "$top_dir/vendor/intel/utils_priv/Android.mk"
    fi
fi

# NOTE: include_preliminary and inlcude_preliminary_priv feature if needed by
# Vertical then will be implemented. As of now it is supported by utils and
# utils_priv repos only.

# Apply Vertical patches if exist
if [[ -e ${vertical_utils_dir} ]] && [[ -d ${vertical_utils_dir} ]];then
        echo -e "\n============================="
        echo "Vertical Patches Found"
        echo "============================="

    if [[ -e ${vertical_patch_dir_aosp}/${TARGET_PRODUCT}/include_preliminary ]];then
        echo -e "\nApply utils_vertical/aosp_diff/preliminary Patches:"
        fpnat "${vertical_patch_dir_aosp}/preliminary"
    fi

    if [[ -e ${vertical_patch_dir_aosp}/${TARGET_PRODUCT} ]] && [[ -d ${vertical_patch_dir_aosp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils_vertical/aosp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${vertical_patch_dir_aosp}/${TARGET_PRODUCT}"
    fi

    if [[ -e ${vertical_patch_dir_bsp}/${TARGET_PRODUCT}/include_common ]];then
        echo -e "\nApply utils_vertical/bsp_diff/common Patches:"
        fpnat "${vertical_patch_dir_bsp}/common"
    fi

    if [[ -e ${vertical_patch_dir_bsp}/${TARGET_PRODUCT} ]] && [[ -d ${vertical_patch_dir_bsp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply utils_vertical/bsp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${vertical_patch_dir_bsp}/${TARGET_PRODUCT}"
    fi

    if [[ "$conflict" == "y" ]]; then
      echo -e "\n\t\tALERT : Conflicts Observed while patch application !!           "
      for i in $conflict_list ; do echo $i; done | sort -u
      echo -e "\n\t\tError: Please resolve Conflict(s) and re-run lunch..."
      echo '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")' > $top_dir/vendor/intel/utils_vertical/Android.mk
    else
      echo -e "\n\t\tSUCCESS : All patches applied SUCCESSFULLY in `basename ${vertical_patch_dir_aosp}` and `basename ${vertical_patch_dir_bsp}`"
      if [[ "$applied_already" == "y" ]]; then
        echo -e "\n\t\tINFO : SOME PATCHES ARE APPLIED ALREADY  !!"
      fi
      clear_conflict_marker "$top_dir/vendor/intel/utils_vertical/Android.mk"
    fi
fi

# Apply Vertical private patches if exist
if [[ -e ${private_vertical_utils_dir} ]] && [[ -d ${private_vertical_utils_dir} ]];then
        echo -e "\n============================="
        echo "Vertical Embargoed Patches Found"
        echo "============================="

    if [[ -e ${private_vertical_patch_dir_aosp}/${TARGET_PRODUCT}/include_preliminary ]];then
        echo -e "\nApply private_utils_vertical/aosp_diff/preliminary Patches:"
        fpnat "${private_vertical_patch_dir_aosp}/preliminary"
    fi

    if [[ -e ${private_vertical_patch_dir_aosp}/${TARGET_PRODUCT} ]] && [[ -d ${private_vertical_patch_dir_aosp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply private_utils_vertical/aosp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${private_vertical_patch_dir_aosp}/${TARGET_PRODUCT}"
    fi

    if [[ -e ${private_vertical_patch_dir_bsp}/${TARGET_PRODUCT}/include_common ]];then
        echo -e "\nApply private_utils_vertical/bsp_diff/common Patches:"
        fpnat "${private_vertical_patch_dir_bsp}/common"
    fi

    if [[ -e ${private_vertical_patch_dir_bsp}/${TARGET_PRODUCT} ]] && [[ -d ${private_vertical_patch_dir_bsp}/${TARGET_PRODUCT} ]];then
        echo -e "\nApply private_utils_vertical/bsp_diff Target ${TARGET_PRODUCT} Patches:"
        fpnat "${private_vertical_patch_dir_bsp}/${TARGET_PRODUCT}"
    fi

    if [[ "$conflict" == "y" ]]; then
      echo -e "\n\t\tALERT : Conflicts Observed while patch application !!           "
      for i in $conflict_list ; do echo $i; done | sort -u
      echo -e "\n\t\tError: Please resolve Conflict(s) and re-run lunch..."
      echo '$(error "Conflicts seen while applying lunch patches !! Resolve and re-trigger")' > $top_dir/vendor/intel/utils_vertical_priv/Android.mk
    else
      echo -e "\n\t\tSUCCESS : All patches applied SUCCESSFULLY in `basename ${private_vertical_patch_dir_aosp}` and `basename ${private_vertical_patch_dir_bsp}`"
      if [[ "$applied_already" == "y" ]]; then
        echo -e "\n\t\tINFO : SOME PATCHES ARE APPLIED ALREADY  !!"
      fi
      clear_conflict_marker "$top_dir/vendor/intel/utils_vertical_priv/Android.mk"
    fi
fi
