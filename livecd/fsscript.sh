#!/bin/bash

echo "Rebuilding module dependencies after new modules built"
depmod -a

echo "Putting back net.eth0"
cd /etc/init.d
ln -s net.lo net.eth0
