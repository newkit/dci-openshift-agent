#!/bin/bash
#
# Copyright (C) 2021-2024 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

PROJECTS=(
    ansible-collection-ansible-posix
    ansible-collection-community-general
    ansible-collection-community-kubernetes
    ansible-collection-community-libvirt
    ansible-collection-containers-podman
    ansible-role-dci-podman
    dci-ansible
    dci-openshift-agent
    dci-openshift-app-agent
    python-dciclient
    python-dciauth
)

unschedule_gerrit_change() {
    number=$1
    if ! grep -qP '^\d+' <<< ${number}; then
        echo "Error: Invalid gerrit change number: ${number}"
        return
    fi

    if ! type -p dci-queue >& /dev/null; then
        echo "dci-queue not found, nothing to unschedule"
        return
    fi

    pools=($(dci-queue list | grep -P "^\s+\w+"))
    if [ ${#pools[@]} -eq 0 ]; then
        echo "No dci-queue pools, nothing to unschedule"
        return
    fi

    for pool in ${pools[@]}; do
        jobid=$(dci-queue list ${pool} | awk -F: '/\/'${number}'-/ {print $1}' | tr -d '[:space:]')
        if [ -n "$jobid" ]; then
            dci-queue unschedule ${pool} ${jobid}
        fi
    done
}

. /etc/dci-openshift-agent/config

if [ -n "$GERRIT_USER" ]; then
    tracking_projects=$(echo "(${PROJECTS[@]})" | tr ' ' '|')
    while :; do
        ssh -i ~/.ssh/"$GERRIT_SSH_ID" -p 29418 $GERRIT_USER gerrit stream-events|while read -r data; do
            type=$(jq -r .type <<< $data)
            project=$(jq -r .change.project <<< $data)
            number=$(jq -r .change.number <<< $data)
            url="$(jq -r .change.url <<< $data | tr -d '\r' | sed 's/[;|&$]//g')"
            # Ignore other projects
            if ! grep -qP "(${tracking_projects})" <<<${project}; then
                continue
            fi
            echo "==========================="
            if [ "$type" = "patchset-created" ]; then
                subject="$(jq -r .change.subject <<< $data)"
                commitMessage="$(jq -r .change.commitMessage <<< $data)"
                echo "$type $project $number \"$subject\" $url =============================="
                dci-auto-launch $number <<< "$commitMessage"
            elif [ "$type" = "comment-added" ]; then
                comment="$(jq -r .comment <<< $data)"
                echo "$type $project $number \"$comment\" $url =============================="
                if grep -Eqi '^\s*re(check|test)\s*$' <<< "$comment"; then
                    commitMessage="$(jq -r .change.commitMessage <<< $data)"
                    dci-auto-launch $number <<< "$commitMessage"
                fi
            elif [ "$type" = "change-abandoned" ]; then
                reason="$(jq -r .reason <<< ${data})"
                echo "${type} ${project} ${number} \"${reason}\" ${url} =============================="
                unschedule_gerrit_change ${number}
            elif [ "$type" = "change-merged" ]; then
                subject="$(jq -r .change.subject <<< $data)"
                echo "${type} ${project} ${number} \"${subject}\" $url} =============================="
                unschedule_gerrit_change ${number}
            fi
        done
        sleep 30
   done
fi

# ci.sh ends here
