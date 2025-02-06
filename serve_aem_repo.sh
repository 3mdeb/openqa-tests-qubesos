#!/bin/bash


if [[ -z $1 ]]; then
    echo "Usage: $0 <repo_directory>"
    exit 1
fi

REPO_DIR=$1

key=$(gpg --batch --gen-key 2>&1 <<END
Key-Type: 1
Key-Length: 2048
Subkey-Type: 1
Subkey-Length: 2048
Name-Real: AEM
Expire-Date: 0
%no-ask-passphrase
%no-protection
END
)
echo $key;

if [[ $key =~ ([0-9A-Z]+)(\.rev) ]]; then
    key_id="${BASH_REMATCH[1]}"
fi

gpg --export -a $key_id > $REPO_DIR/RPM-GPG-KEY-aem
rpm --import RPM-GPG-KEY-aem
rpm --define "_gpg_name $key_id" --addsign $REPO_DIR/rpm/*.rpm
gpg --batch --yes --delete-secret-key $key_id
gpg --batch --yes --delete-key $key_id

createrepo_c $REPO_DIR
cd $REPO_DIR && python3 -m http.server