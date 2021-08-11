#!/bin/sh -ex

### git-remote-codecommit ###
pip install --upgrade pip
pip3 install git-remote-codecommit --no-warn-script-location

if [ -f "/usr/local/bin/git-remote-codecommit" ]; then
    cp /usr/local/bin/git-remote-codecommit /tools
    cp /usr/local/lib/python3.9/site-packages/git_remote_codecommit/__init__.py /tools
else
    dir=`python -m site --user-site`
    cp ~/.local/bin/git-remote-codecommit /tools
    cp "$dir/git_remote_codecommit/__init__.py" /tools
fi

# On the ArgoCD container, python3 is available under /usr/bin/python3
sed -i 's|/usr/local/bin/python|/usr/bin/python3|' /tools/git-remote-codecommit
chmod a+x /tools/git-remote-codecommit

### envsubst and wget ###
apt-get update
apt-get -y install gettext-base wget
apt-get clean
rm -rf /var/lib/apt/lists/*
cp /usr/bin/envsubst /tools

### kustomize v3.5.4 ###
# Pins kustomize to v3.5.4 (later versions have performance problems)
wget -qO /tools/kustomize_3_5_4 \
    https://ping-artifacts.s3-us-west-2.amazonaws.com/pingcommon/kustomize/3.5.4/linux_amd64/kustomize
chmod a+x /tools/kustomize_3_5_4