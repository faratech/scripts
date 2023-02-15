#!/bin/bash

# Pause the MariaDB database server
mysql -u root -pXXXX -e "FLUSH TABLES WITH READ LOCK;"

# Pause the Litespeed web server
/usr/local/lsws/bin/lswsctrl graceful

# Close the Elasticsearch index
curl -X POST "http://localhost:9200/index_index/_close"

# Flush all filesystem writes to disk
sync

# Freeze the XFS filesystem to ensure all writes are completed
xfs_freeze -f /
