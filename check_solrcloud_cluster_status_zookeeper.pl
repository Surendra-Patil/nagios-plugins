#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2013-02-03 09:46:19 +0000 (Sun, 03 Feb 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

$DESCRIPTION = "Nagios Plugin to check SolrCloud cluster state, specifically collection shards and replicas, via ZooKeeper contents

Checks:

For a given SolrCloud Collection or all collections found if --collection is not specified:

1. Checks there is at least one collection found
2. Checks each shard of the collection is 'active'
3. Checks each shard of the collection has at least one active replica
4. Checks each shard for any down backup replicas (can be optionally disabled)
5. Optionally shows replication settings per collection
6. Returns time since last cluster state change in both human form and perfdata secs for graphing

See also adjacent plugin check_solrcloud_cluster_status.pl which does the same as this plugin but directly via the Solr API on one of the SolrCloud servers instead of ZooKeeper, so doesn't require Net::ZooKeeper to be built.

Tested on ZooKeeper 3.4.5 / 3.4.6 with SolrCloud 4.x

API / BUGS / Limitations:

Uses the Net::ZooKeeper perl module which leverages the ZooKeeper Client C API. Instructions for installing Net::ZooKeeper are found at https://github.com/harisekhon/nagios-plugins

1. Net::ZooKeeper API is slow, takes 5 seconds to create a connection object per ZooKeeper node specified (before it even tries to connect to ZooKeeper which happenes sub-second). Unfortunately this is a limitation of the Net::ZooKeeper API
2. API segfaults if you try to check the contents of a null znode such as those kept by SolrCloud servers eg. /solr/live_nodes/<hostname>:8983_solr - ie this will occur if you supply the incorrect base znode and it happens to be null
";

$VERSION = "0.4.1";

use strict;
use warnings;
use IO::Socket;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
    use lib "/usr/local/lib";
}
use HariSekhonUtils qw/:DEFAULT :time/;
use HariSekhon::Solr;
use HariSekhon::ZooKeeper;

# Max num of chars to read from znode contents
$DATA_READ_LEN = 50000;
#my $max_age = 600; # secs

my $znode = "/clusterstate.json";
my $base = "/solr";

env_vars("SOLR_COLLECTION", \$collection);

%options = (
    %zookeeper_options,
    "b|base=s"         => [ \$base,             "Base Znode for Solr in ZooKeeper (default: /solr, should be just / for embedded or non-chrooted zookeeper)" ],
    "C|collection=s"   => [ \$collection,       "Solr Collection to check (defaults to all if not specified, \$SOLR_COLLECTION)" ],
    "no-warn-replicas" => [ \$no_warn_replicas, "Do not warn on down backup replicas (only check for shards being active and having at least one active replica)" ],
    "show-settings"    => [ \$show_settings,    "Show collection shard/replication settings" ],
    "list-collections" => [ \$list_collections, "List Solr Collections and exit" ],
    #"a|max-age=s" =>  [ \$max_age,    "Max age of the clusterstate znode information in seconds (default: 600)" ],
);
splice @usage_order, 6, 0, qw/collection base no-warn-replicas show-settings max-age list-collections random-conn-order session-timeout/;

get_options();

my @hosts   = validate_hosts($host, $port);
$znode      = validate_base_and_znode($base, $znode, "clusterstate");
$collection = validate_solr_collection($collection) if $collection;
#validate_thresholds(0, 1, { 'simple' => 'upper', 'positive' => 1, 'integer' => 1}, "max znode age", $max_age);

$user     = validate_user($user)         if defined($user);
$password = validate_password($password) if defined($password);

vlog2;
set_timeout();

$status = "OK";

connect_zookeepers(@hosts);

check_znode_exists($znode);

# we don't get a session id until after a call to the server such as exists() above
#my $session_id = $zkh->{session_id} or quit "UNKNOWN", "failed to determine ZooKeeper session id, possibly not connected to ZooKeeper?";
#vlog2 sprintf("session id: %s", $session_id);

$json = get_znode_contents_json($znode);

unless(scalar keys %$json){
    quit "CRITICAL", "no collections found in cluster state in zookeeper";
}

if($list_collections){
    print "Solr Collections:\n\n";
    foreach(sort keys %$json){
        print "$_\n";
    }
    exit $ERRORS{"UNKNOWN"};
}

check_collections();

msg_shard_status();

get_znode_age($znode);
$msg .= sprintf(". Cluster state last changed %s ago", sec2human($znode_age_secs));
$msg .= " | cluster_state_last_changed=${znode_age_secs}s";

vlog2;
quit $status, $msg;
