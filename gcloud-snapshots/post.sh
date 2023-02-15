#!/bin/bash

# Unfreeze the XFS filesystem
xfs_freeze -u /

# Resume the Litespeed web server
/usr/local/lsws/bin/lswsctrl start

# Release the read lock on the MariaDB database server
mysql -u root -pXXXX -e "UNLOCK TABLES;"

# Unfreeze the Elasticsearch index
curl -X POST "http://localhost:9200/index_index/_open"
