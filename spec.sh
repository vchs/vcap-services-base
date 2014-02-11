#!/bin/bash
set -x
set -e

proj_root=$(dirname $(readlink -f $0))
WARDEN_PKG=/var/vcap/packages/warden/services_warden/warden

mkdir -p /var/vcap/sys/log/warden

# dynamically generate the config for the warden server
cat > /tmp/warden_server.yml <<-EOF
---
server:
  container_klass: Warden::Container::Linux
  container_grace_time: 300
  unix_domain_permissions: 0777
  container_rootfs_path: /var/vcap/data/warden/rootfs
  container_depot_path: /var/vcap/data/warden/depot/
  container_limits_conf:
    nofile: 8192
    nproc: 512
    as: 4194304
  quota:
    disk_quota_enabled: false
  allow_nested_warden: true
logging:
  level: debug2

network:
  pool_start_address: 60.254.0.0
  pool_size: 256

user:
  pool_start_uid: 20000
  pool_size: 256
EOF

pushd $WARDEN_PKG
nohup bundle exec rake warden:start[/tmp/warden_server.yml] >> \
  /var/vcap/sys/log/warden/warden.stdout.log &
popd

cd $proj_root
rm -rf .bundle vendor/bundle
bundle install --without development production --path vendor/bundle
bundle exec rake ci:setup:rspec spec
tar czvf reports.tgz spec/reports
tar czvf coverage.tgz coverage
