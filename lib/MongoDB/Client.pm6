use v6;

#TODO readconcern does not have to be a BSON::Document. no encoding!

use MongoDB;
use MongoDB::Uri;
use MongoDB::ServerPool::Server;
use MongoDB::ServerPool;
use MongoDB::Server::Monitor;
use MongoDB::Database;
use MongoDB::Collection;
use MongoDB::ObserverEmitter;

use BSON::Document;
use Semaphore::ReadersWriters;

INIT {
  # start monitoring in a separate thread as early as possible
  MongoDB::Server::Monitor.instance;
}

#-------------------------------------------------------------------------------
unit class MongoDB::Client:auth<github:MARTIMM>:ver<0.1.0>;

has Array $!topology-description = [];

has Bool $!topology-set;

# Store all found servers here. key is the name of the server which is
# the server address/ip and its port number. This should be unique. The
# data is a Hash of Hashes.
#has Hash $!servers;

#has $!observed-servers;

has Semaphore::ReadersWriters $!rw-sem;

has Str $!uri;
has MongoDB::Uri $.uri-obj; # readable for several modules

has Str $!Replicaset;

#  has Promise $!background-discovery;
#has Bool $!repeat-discovery-loop;

# Only for single threaded implementations according to mongodb documents
# has Bool $!server-selection-try-once = False;
# has Int $!socket-check-interval-ms = 5000;

# Cleaning up is done concurrently so the test on a variable like $!servers
# to be undefined, will not work. Instead check if the below variable is True
# to see if destroying the client is started.
has Bool $!cleanup-started = False;

#`{{ canot overide =
#-------------------------------------------------------------------------------
sub infix:<=>( MongoDB::Client $a is rw, MongoDB::Client $b ) is export {
  if $a.defined {
    warn-message('Old client object is defined, will be forcebly cleaned');
    $a.cleanup;
  }

  $a := $b;
}
}}

# Settings according to mongodb specification
# See https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#heartbeatfrequencyms
# names are written in camelback form, here all lowercase with dashes.
# serverSelectionTryOnce and socketCheckIntervalMS are not supported because
# this is a multi-threaded implementation.
has Int $!local-threshold-ms;
has Int $!server-selection-timeout-ms;
has Int $!heartbeat-frequency-ms;

#-------------------------------------------------------------------------------
method new ( |c ) {

  # In case of an assignement like $c .= new(...) $c should be cleaned first
  if self.defined and not $!cleanup-started {

    warn-message('user client object still defined, will be cleaned first');
    self.cleanup;
  }

  MongoDB::Client.bless(|c);
}

#-------------------------------------------------------------------------------
#TODO pod doc arguments
submethod BUILD ( Str:D :$!uri ) {

  # set a few specification settings
  $!local-threshold-ms = C-LOCALTHRESHOLDMS;
  $!server-selection-timeout-ms = C-SERVERSELECTIONTIMEOUTMS;
  $!heartbeat-frequency-ms = C-HEARTBEATFREQUENCYMS;


  $!topology-description[Topo-type] = TT-NotSet;
  $!topology-set = False;
  trace-message("init client, topology set to {TT-NotSet}");

#  $!servers = %();
#  $!observed-servers = %();

  # initialize mutexes
  $!rw-sem .= new;
#    $!rw-sem.debug = True;

  $!rw-sem.add-mutex-names(
    <servers todo topology>, :RWPatternType(C-RW-WRITERPRIO)
  );

#`{{ TODO next structure could not have been a read concern description
     it should have been something else, but what???

#TODO check version: read-concern introduced in version 3.2
  # Store read concern or initialize to default
  $!read-concern = $read-concern // BSON::Document.new: (
    mode => RCM-Primary,
#TODO  next key only when max-wire-version >= 5 ??
#      max-staleness-seconds => 90,
#      must be > C-SMALLEST-MAX-STALENEST-SECONDS
#           or > $!heartbeat-frequency-ms + $!idle-write-period-ms
    tag-sets => [BSON::Document.new(),]
  );
}}

  # parse the uri and get info in $!uri-obj. fields are protocol, username,
  # password, servers, database and options.
#  $!uri = $uri;
  $!uri-obj .= new(:$!uri);

  # set the heartbeat frequency by emitting the value found in the URI
  # to the monitor thread
  my MongoDB::ObserverEmitter $event-manager .= new;
  $event-manager.emit(
    'set heartbeatfrequency ms',
    $!uri-obj.options<heartbeatFrequencyMS>
  );

  # Setup todo list with servers to be processed, Safety net not needed
  # because threads are not yet started.
  trace-message("Found {$!uri-obj.servers.elems} servers in uri");
  for @($!uri-obj.servers) -> Hash $server-data {
    my Str $server-name = "$server-data<host>:$server-data<port>";

    if !$event-manager.check-subscription(
      "$!uri-obj.client-key() $server-name process topology"
    ) {
      # this client receives the data from a server in a List to be
      # processed by process-topology().
      $event-manager.subscribe-observer(
        $server-name ~ ' process topology',
        -> List $server-data { self!process-topology(|$server-data); },
        :event-key("$!uri-obj.client-key() $server-name process topology")
      );

      # this client gets new host information from the server. it is
      # possible that hosts are processed before.
      $event-manager.subscribe-observer(
        $server-name ~ ' add servers',
        -> @new-hosts { self!add-servers(@new-hosts); },
        :event-key("$!uri-obj.client-key() $server-name add servers")
      );
    }

    # A server is stored in a pool and can be shared among different clients.
    # The information comes from some server to these clients. Therefore the
    # key must be a server name attached to some string. The folowing observer
    # steps must be done per added server.
#    unless $!observed-servers{$server-name} {

    # create Server object
    my MongoDB::ServerPool $server-pool .= instance;

    # this client gets new host information from the server. it is
    # possible that hosts are processed before.
    my Bool $created = $server-pool.add-server(
        $!uri-obj.client-key, $server-name, #$!uri-obj,
#        :status(ST-Unknown), :!ismaster
    );

    unless $created {
      $server-pool.set-server-data( $server-name, :$!uri-obj);
trace-message("Server $server-name already there, try to find topology");
      self!process-topology( $server-name, ServerType, Bool);
    }
  }
}

#-------------------------------------------------------------------------------
submethod DESTROY ( ) {

  if self.defined and not $!cleanup-started {

    warn-message('Destroy client');
    self.cleanup;
  }
}

#-------------------------------------------------------------------------------
method !process-topology (
  Str:D $new-server-name, ServerType $server-status, Bool $is-master
) {
  # update server data
#  self!update-server( $new-server-name, $server-status, $is-master);

  my MongoDB::ServerPool $server-pool .= instance;

  if $server-status.defined and $is-master.defined {
    $server-pool.set-server-data(
      $new-server-name, :status($server-status), :$is-master
    );
    trace-message("server info updated for $new-server-name with $server-status, $is-master");
  }
  else {
    trace-message("server info updated for $new-server-name");
  }


  # find topology
  my TopologyType $topology = TT-Unknown;
#  my Hash $servers = $!rw-sem.reader( 'servers', { $!servers.clone; });
  my Int $servers-count = 0;

  my Bool $found-standalone = False;
  my Bool $found-sharded = False;
  my Bool $found-replica = False;

#  my @server-list = |($server-pool.get-server-names($!uri-obj.client-key));
#trace-message("client '$!uri-obj.keyed-obj()'");

  for @($server-pool.get-server-names($!uri-obj.client-key)) -> $server-name {
#  for $servers.keys -> $server-name {
    $servers-count++;

    # check status of server
    my ServerType $sts = $server-pool.get-server-data( $server-name, 'status');
    given $sts {
      when ST-Standalone {
#        $servers-count++;

        # cannot have more than one standalone servers
        if $found-standalone or $found-sharded or $found-replica {
          $topology = TT-Unknown;
        }

        else {
          # set standalone server
          $found-standalone = True;
          $topology = TT-Single;
        }
      }

      when ST-Mongos {
#        $servers-count++;

        # cannot have other than shard servers
        if $found-standalone or $found-replica {
          $topology = TT-Unknown;
        }

        else {
          $found-sharded = True;
          $topology = TT-Sharded;
        }
      }

#TODO test same set of replicasets -> otherwise also TT-Unknown
      when ST-RSPrimary {
#        $servers-count++;

        # cannot have other than replica servers
        if $found-standalone or $found-sharded {
          $topology = TT-Unknown;
        }

        else {
          $found-replica = True;
          $topology = TT-ReplicaSetWithPrimary;
        }
      }

      when any( ST-RSSecondary, ST-RSArbiter, ST-RSOther, ST-RSGhost ) {
#        $servers-count++;

        # cannot have other than replica servers
        if $found-standalone or $found-sharded {
          $topology = TT-Unknown;
        }

        else {
          $found-replica = True;
          $topology //= TT-ReplicaSetNoPrimary;
#            unless $topology ~~ TT-ReplicaSetWithPrimary;
        }
      }
    } # given $status
  } # for $servers.keys -> $server-name

  # If one of the servers is not ready yet, topology is still TT-NotSet
  unless $topology ~~ TT-NotSet {

    # make it single under some conditions
    $topology = TT-Single
      if $servers-count == 1 and $!uri-obj.options<replicaSet>:!exists;


    $!rw-sem.writer( 'topology', {
        $!topology-description[Topo-type] = $topology;
        $!topology-set = True;
      }
    );
  }

  # set topology info in ServerPool to store with the server
  $server-pool.set-server-data( $new-server-name, :$topology);

  info-message("Client '$!uri-obj.client-key()' topology is $topology");
}

#`{{
#-------------------------------------------------------------------------------
method process-topology-old ( ) {

  $!rw-sem.writer( 'topology', { $!topology-set = False; });

#TODO take user topology request into account
  # Calculate topology. Upon startup, the topology is set to
  # TT-Unknown. Here, the real value is calculated and set. Doing
  # it repeatedly it will be able to change dynamicaly.
  #
  my TopologyType $topology = TT-Unknown;
  my Hash $servers = $!rw-sem.reader( 'servers', {$!servers.clone;});
  my Int $servers-count = 0;

  my Bool $found-standalone = False;
  my Bool $found-sharded = False;
  my Bool $found-replica = False;

  for $servers.keys -> $server-name {

    my ServerType $status =
      $servers{$server-name}.get-status<status> // ST-Unknown;

    # check status of server
    given $status {
      when ST-Standalone {
        $servers-count++;
        if $found-standalone or $found-sharded or $found-replica {

          # cannot have more than one standalone servers
          $topology = TT-Unknown;
        }

        else {

          # set standalone server
          $found-standalone = True;
          $topology = TT-Single;
        }
      }

      when ST-Mongos {
        $servers-count++;
        if $found-standalone or $found-replica {

          # cannot have other than shard servers
          $topology = TT-Unknown;
        }

        else {
          $found-sharded = True;
          $topology = TT-Sharded;
        }
      }

#TODO test same set of replicasets -> otherwise also TT-Unknown
      when ST-RSPrimary {
        $servers-count++;
        if $found-standalone or $found-sharded {

          # cannot have other than replica servers
          $topology = TT-Unknown;
        }

        else {

          $found-replica = True;
          $topology = TT-ReplicaSetWithPrimary;
        }
      }

      when any( ST-RSSecondary, ST-RSArbiter, ST-RSOther, ST-RSGhost ) {
        $servers-count++;
        if $found-standalone or $found-sharded {

          # cannot have other than replica servers
          $topology = TT-Unknown;
        }

        else {

          $found-replica = True;
          $topology = TT-ReplicaSetNoPrimary
            unless $topology ~~ TT-ReplicaSetWithPrimary;
        }
      }
    } # given $status
  } # for $servers.keys -> $server-name

  # One of the servers is not ready yet
  if $topology !~~ TT-NotSet {

    if $servers-count == 1 and $!uri-obj.options<replicaSet>:!exists {
      $topology = TT-Single;
    }

    $!rw-sem.writer( 'topology', {
        $!topology-description[Topo-type] = $topology;
        $!topology-set = True;
      }
    );
  }

  info-message("Client topology is $topology");
}
}}

#`{{ not used?
#-------------------------------------------------------------------------------
# Return number of servers
method nbr-servers ( --> Int ) {

  $!rw-sem.reader( 'servers', {$!servers.elems;});
}
}}

#-------------------------------------------------------------------------------
# Get the server status
method server-status ( Str:D $server-name --> ServerType ) {

  #! Wait until topology is set
  until $!rw-sem.reader( 'topology', { $!topology-set }) {
    sleep 0.5;
  }

#`{{
  my Hash $h = $!rw-sem.reader(
    'servers', {
    my $x = $!servers{$server-name}:exists
            ?? $!servers{$server-name}<server>.get-status
            !! {};
    $x;
  });

  my ServerType $sts = $h<status> // ST-Unknown;
}}

  my MongoDB::ServerPool $server-pool .= instance;
  my ServerType $sts = $server-pool.get-server-data( $server-name, 'status');
#note "server-status: '$server-name', {$sts // ST-Unknown}";
  $sts // ST-Unknown;
}

#-------------------------------------------------------------------------------
method topology ( --> TopologyType ) {

  #! Wait until topology is set
  until $!rw-sem.reader( 'topology', { $!topology-set }) {
    sleep 0.5;
  }

  $!rw-sem.reader( 'topology', {$!topology-description[Topo-type]});
}

#-------------------------------------------------------------------------------
# Selecting servers based on;
#
# - Record the server selection start time
# - If the topology wire version is invalid, raise an error
# - Find suitable servers by topology type and operation type
# - If there are any suitable servers, choose one at random from those within
#   the latency window and return it; otherwise, continue to step #5
# - Request an immediate topology check, then block the server selection
#   thread until the topology changes or until the server selection timeout
#   has elapsed
# - If more than serverSelectionTimeoutMS milliseconds have elapsed since the
#   selection start time, raise a server selection error
# - Goto Step #2
#-------------------------------------------------------------------------------

#`{{
#-------------------------------------------------------------------------------
# Request specific servername
multi method select-server ( Str:D :$servername! --> MongoDB::ServerPool::Server ) {

  # record the server selection start time. used also in debug message
  my Instant $t0 = now;

  my MongoDB::ServerPool::Server $selected-server;

  # find suitable servers by topology type and operation type
  repeat {

    #! Wait until topology is set
    until $!rw-sem.reader( 'topology', { $!topology-set }) {
      sleep 0.5;
    }

    $selected-server = $!rw-sem.reader( 'servers', {
#note "ss0 Servers: ", $!servers.keys;
#note "ss0 Request: $selected-server.name()";
        $!servers{$servername}:exists
                ?? $!servers{$servername}<server>
                !! MongoDB::ServerPool::Server;
      }
    );

    last if ? $selected-server;
    sleep $!uri-obj.options<heartbeatFrequencyMS> / 1000.0;
  } while ((now - $t0) * 1000) < $!uri-obj.options<serverSelectionTimeoutMS>;

  debug-message("Searched for {((now - $t0) * 1000).fmt('%.3f')} ms");

  if ?$selected-server {
    debug-message("Server '$selected-server.name()' selected");
  }

  else {
    warn-message("No suitable server selected");
  }

  $selected-server;
}
}}


#TODO pod doc
#TODO use read/write concern for selection
#TODO must break loop when nothing is found
#-------------------------------------------------------------------------------
# Read/write concern selection
#multi method select-server (
method select-server ( --> MongoDB::ServerPool::Server ) {

  #! Wait until topology is set
  until $!rw-sem.reader( 'topology', { $!topology-set }) {
#note "wait 0.5: $*THREAD.id()";
    sleep 0.3;
  }

#  my Array $topology-description = $!rw-sem.reader(
#    'topology', { $!topology-description }
#  );
#note "topo: ", $topology-description.perl;

  my MongoDB::ServerPool $server-pool .= instance;
  $server-pool.select-server($!uri-obj.client-key);
}

#`{{
#-------------------------------------------------------------------------------
# Read/write concern selection
#multi method select-server (
method select-server ( --> MongoDB::ServerPool::Server ) {

  my MongoDB::ServerPool::Server $selected-server;

  # record the server selection start time. used also in debug message
  my Instant $t0 = now;

  #! Wait until topology is set
  until $!rw-sem.reader( 'topology', { $!topology-set }) {
note "wait 0.5: $*THREAD.id()";
    sleep 0.5;
  }

  # find suitable servers by topology type and operation type
  repeat {

    my MongoDB::ServerPool::Server @selected-servers = ();
    my Hash $servers = $!rw-sem.reader( 'servers', {$!servers.clone});
    my TopologyType $topology = $!rw-sem.reader(
      'topology', {$!topology-description[Topo-type]
    });

note "ss1 Servers: ", $servers.keys;
note "ss1 Topology: $topology";

    given $topology {
      when TT-Single {

        for $servers.keys -> $sname {
          $selected-server = $servers{$sname}<server>;
          my Hash $sdata = $selected-server.get-status;
          last if $sdata<status> ~~ ST-Standalone;
        }
      }

      when TT-ReplicaSetWithPrimary {

#TODO read concern
#TODO check replica set option in uri
        for $servers.keys -> $sname {
          $selected-server = $servers{$sname}<server>;
          my Hash $sdata = $selected-server.get-status;
          last if $sdata<status> ~~ ST-RSPrimary;
        }
      }

      when TT-ReplicaSetNoPrimary {

#TODO read concern
#TODO check replica set option in uri if ST-RSSecondary
        for $servers.keys -> $sname {
          my $s = $servers{$sname}<server>;
          my Hash $sdata = $s.get-status;
          @selected-servers.push: $s if $sdata<status> ~~ ST-RSSecondary;
        }
      }

      when TT-Sharded {

        for $servers.keys -> $sname {
          my $s = $servers{$sname}<server>;
          my Hash $sdata = $s.get-status;
          @selected-servers.push: $s if $sdata<status> ~~ ST-Mongos;
        }
      }
    }

    # if no server selected but there are some in the array
    if !$selected-server and +@selected-servers {

      # if only one server in array, take that one
      if @selected-servers.elems == 1 {
        $selected-server = @selected-servers.pop;
      }

      # now w're getting complex because we need to select from a number
      # of suitable servers.
      else {

        my Array $slctd-svrs = [];
        my Duration $min-rtt-ms .= new(1_000_000_000);

        # get minimum rtt from server measurements
        for @selected-servers -> MongoDB::ServerPool::Server $svr {
          my Hash $svr-sts = $svr.get-status;
          $min-rtt-ms = $svr-sts<weighted-mean-rtt-ms>
            if $min-rtt-ms > $svr-sts<weighted-mean-rtt-ms>;
        }

        # select those servers falling in the window defined by the
        # minimum round trip time and minimum rtt plus a treshold
        for @selected-servers -> $svr {
          my Hash $svr-sts = $svr.get-status;
          $slctd-svrs.push: $svr
            if $svr-sts<weighted-mean-rtt-ms> <= (
              $min-rtt-ms + $!uri-obj.options<localThresholdMS>
            );
        }

        $selected-server = $slctd-svrs.pick;
      }
    }

    # done when a suitable server is found
    last if $selected-server.defined;

    # else wait for status and topology updates
#TODO synchronize with monitor times
    sleep $!uri-obj.options<heartbeatFrequencyMS> / 1000.0;

  } while ((now - $t0) * 1000) < $!uri-obj.options<serverSelectionTimeoutMS>;

  debug-message("Searched for {((now - $t0) * 1000).fmt('%.3f')} ms");

  if ?$selected-server {
    debug-message("Server '$selected-server.name()' selected");
  }

  else {
    warn-message("No suitable server selected");
  }

  $selected-server;
}
}}

#-------------------------------------------------------------------------------
# Add server to todo list.
method !add-servers ( @new-hosts ) {

  trace-message("push @new-hosts[*] on todo list");
try {
  my MongoDB::ObserverEmitter $event-manager .= new;
  my MongoDB::ServerPool $server-pool .= instance;
  for @new-hosts -> Str $server-name {

    # A server is stored in a pool and can be shared among different clients.
    # The information comes from some server to these clients. Therefore the
    # key must be a server name attached to some string. The folowing observer
    # steps must be done per added server.

#    unless $!observed-servers{$server-name} {

    if !$event-manager.check-subscription(
      "$!uri-obj.client-key() $server-name process topology"
    ) {
      # this client receives the data from a server in a List to be processed by
      # process-topology().
      $event-manager.subscribe-observer(
        $server-name ~ ' process topology',
        -> List $server-data { self!process-topology(|$server-data); },
        :event-key("$!uri-obj.client-key() $server-name process topology")
      );

      # this client gets new host information from the server. it is
      # possible that hosts are processed before.
      $event-manager.subscribe-observer(
        $server-name ~ ' add servers',
        -> @new-hosts { self!add-servers(@new-hosts); },
        :event-key("$!uri-obj.client-key() $server-name add servers")
      );
    }

    # create Server object, if server already existed, get the
    # info from server immediately
    my Bool $created = $server-pool.add-server(
      $!uri-obj.client-key, $server-name
    );
    unless $created {
      $server-pool.set-server-data( $server-name, :$!uri-obj);
trace-message("Server $server-name already there, try to find topology");
#      self!process-topology( $server-name, ServerType, Bool);
    }
  }
CATCH {.note;}
}
}

#-------------------------------------------------------------------------------
method database ( Str:D $name --> MongoDB::Database ) {
  MongoDB::Database.new( :$!uri-obj, :name($name));
}

#-------------------------------------------------------------------------------
method collection ( Str:D $full-collection-name --> MongoDB::Collection ) {

#TODO check for dot in the name
  ( my $db-name, my $cll-name) = $full-collection-name.split( '.', 2);
  my MongoDB::Database $db .= new( :$!uri-obj, :name($db-name));
  $db.collection($cll-name)
}

#-------------------------------------------------------------------------------
# Forced cleanup
#
# cleanup cannot be done in separate thread because everything must be cleaned
# up before other tasks are performed.
method cleanup ( ) {

  $!cleanup-started = True;

  # some timing to see if this cleanup can be improved
  my Instant $t0 = now;

  my MongoDB::ServerPool $server-pool .= instance;
  my MongoDB::ObserverEmitter $e .= new;
  for @($server-pool.get-server-names($!uri-obj.client-key)) -> Str $sname {
    $e.unsubscribe-observer("$!uri-obj.client-key() $sname process topology");
    $e.unsubscribe-observer("$!uri-obj.client-key() $sname add servers");
  }

  # stop loop and wait for exit
  #if $!repeat-discovery-loop {
  #  $!repeat-discovery-loop = False;
#      $!background-discovery.result;
  #}

  # Remove all servers concurrently. Shouldn't be many per client.
  $server-pool.cleanup($!uri-obj.client-key);

#`{{
  $!rw-sem.writer(
    'servers', {

      for $!servers.values -> Hash $server-data {
        my MongoDB::ServerPool::Server $server = $server-data<server>;
        if $server.defined {
          # Stop monitoring on server
          $server.cleanup;
          debug-message(
            "server '$server.name()' destroyed after {(now - $t0)} sec"
          );
        }
      }
    }
  );
}}
  # unsubscribe observers

#  $!servers = Nil;
  $!rw-sem.rm-mutex-names(<servers todo topology>);
  debug-message("Client destroyed after {(now - $t0)} sec");
}
