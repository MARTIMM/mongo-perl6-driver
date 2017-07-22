use v6;

#TODO readconcern does not have to be a BSON::Document. no encoding!

#-------------------------------------------------------------------------------
unit package MongoDB:auth<github:MARTIMM>;

use MongoDB;
use MongoDB::Uri;
use MongoDB::Server;
use MongoDB::Database;
use MongoDB::Collection;
use MongoDB::Wire;
use MongoDB::Authenticate::Credential;

use BSON::Document;
use Semaphore::ReadersWriters;

#-------------------------------------------------------------------------------
class Client {

  # topology-set is used to block the server-select() process when topology still
  # needs to be calculated.
  has TopologyType $!topology-type;
  has TopologyType $!user-request-topology;
  has Bool $!topology-set;

  # Store all found servers here. key is the name of the server which is
  # the server address/ip and its port number. This should be unique.
  has Hash $!servers;
  has Array $!todo-servers;

  has Semaphore::ReadersWriters $!rw-sem;

  has Str $!uri;
  has Hash $.uri-data;

  has BSON::Document $.read-concern;
  has Str $!Replicaset;

  has Promise $!Background-discovery;
  has Bool $!repeat-discovery-loop;

  # https://github.com/mongodb/specifications/blob/master/source/auth/auth.rst#client-implementation
  has MongoDB::Authenticate::Credential $.credential;

  # https://github.com/mongodb/specifications/blob/master/source/server-selection/server-selection.rst#mongoclient-configuration
  has Int $!local-threshold-ms;
  has Int $!server-selection-timeout-ms;
  has Int $!heartbeat-frequency-ms;
#  has Int $!idle-write-period-ms;
  constant smallest-max-staleness-seconds = 90;

  # Only for single threaded implementations
  # has Bool $!server-selection-try-once = False;
  # has Int $!socket-check-interval-ms = 5000;

  # Cleaning up is done concurrently so the test on a variable like $!servers
  # to be undefined, will not work. Instead check if the below variable is True
  # to see if destroying the client is started.
  has Bool $!cleanup-started = False;

  #-----------------------------------------------------------------------------
  method new ( |c ) {

    # In case of an assignement like $c .= new(...) $c should be cleaned first
    if self.defined and not $!cleanup-started {

      warn-message('User client object still defined, will be cleaned first');
      self.cleanup;
#      sleep 0.5;
    }

    MongoDB::Client.bless(|c);
  }

  #-----------------------------------------------------------------------------
#TODO pod doc arguments
  submethod BUILD (
    Str:D :$uri, BSON::Document :$read-concern,
    TopologyType :$topology-type = TT-Unknown,
#    Int :$!idle-write-period-ms = 10_000,
  ) {

    $!user-request-topology = $topology-type;
    $!topology-type = TT-Unknown;
    $!topology-set = False;

    $!servers = {};
    $!todo-servers = [];

    # Initialize mutexes
    $!rw-sem .= new;
#    $!rw-sem.debug = True;

    $!rw-sem.add-mutex-names(
      <servers todo topology>,
      :RWPatternType(C-RW-WRITERPRIO)
    ) unless $!rw-sem.check-mutex-names(<servers todo master>);

#TODO check version: read-concern introduced in version 3.2
    # Store read concern or initialize to default
    $!read-concern = $read-concern // BSON::Document.new: (
      mode => RCM-Primary,
#TODO  next key only when max-wire-version >= 5 ??
#      max-staleness-seconds => 90,
#      must be > smallest-max-staleness-seconds
#           or > $!heartbeat-frequency-ms + $!idle-write-period-ms
      tag-sets => [BSON::Document.new(),]
    );

    # Parse the uri and get info in $uri-obj. Fields are protocol, username,
    # password, servers, database and options.
    $!uri = $uri;

    # Copy some fields into $!uri-data hash which is handed over
    # to the server object..
    my @item-list = <username password database options>;
    my MongoDB::Uri $uri-obj .= new(:$!uri);
    $!uri-data = %(@item-list Z=> $uri-obj.server-data{@item-list});

    # Get some connection options from the uri
    $!local-threshold-ms = ($!uri-data<options><localThresholdMS> // 15).Int;
    $!server-selection-timeout-ms =
         ($!uri-data<options><serverSelectionTimeoutMS> // 30_000).Int;
    $!heartbeat-frequency-ms =
         ($!uri-data<options><heartbeatFrequencyMS> // 10_000).Int;

    my %cred-data = %();
    my $set = sub ( *@k ) {
      my $sk = shift @k;
      for @k -> $rk {
        return if %cred-data{$sk};
        %cred-data{$sk} = $uri-obj.server-data{$rk}
          if ? $rk and ? $uri-obj.server-data{$rk};
      }
    };

    $set( 'username',                   'username');
    $set( 'password',                   'password');
    $set( 'auth-source',                'database', 'authSource', 'admin');
    $set( 'auth-mechanism',             'authMechanism');
    $set( 'auth-mechanism-properties',  'authMechanismProperties');
    $!credential .= new(|%cred-data);

    debug-message("Found {$uri-obj.server-data<servers>.elems} servers in uri");

    # Setup todo list with servers to be processed, Safety net not needed yet
    # because threads are not started.
    for @($uri-obj.server-data<servers>) -> Hash $server-data {
      debug-message("todo: $server-data<host>:$server-data<port>");
      $!todo-servers.push("$server-data<host>:$server-data<port>");
    }

    # counter to check if there are new servers added. if so, the counter
    # is set to 0. if less then 5 the sleeptime is about a second. When count
    # reaches max, the thread is stopped.
    my Int $changes-count = 0;

    # Background proces to handle server monitoring data
    $!Background-discovery = Promise.start( {

        # Used in debug message
        my Instant $t0 = now;

        $!repeat-discovery-loop = True;
        repeat {

          # count to some limit when no servers are found then stop. if a
          # server is found, count is reset.
          $changes-count = self!discover-servers ?? 0 !! $changes-count + 1;

          # When there is no work take a nap! This sleeping period is the
          # moment we do not process the todo list. Start taking a nap for 1.1
          # sec.
          if $changes-count < 10 {
            sleep 1.1;
          }

          else {
            # stop the loop and exit thread. for new changes, discover-servers()
            # is called later via select-server().
            $!repeat-discovery-loop = False;
          }

          CATCH {
            default {
               # Keep this .note in. It helps debugging when an error takes place
               # The error will not be seen before the result of Promise is read
               .note;
               .rethrow;
            }
          }

          debug-message("One client processing cycle done after {(now - $t0) * 1000} ms");
        } while $!repeat-discovery-loop;

        debug-message("server discovery loop stopped");
        'normal end of service';
      } # block
    ); # start
  }

  #-----------------------------------------------------------------------------
  method process-topology ( ) {

#    $!rw-sem.writer( 'topology', {
    $!rw-sem.writer( 'topology', {
        $!topology-set = False;
      }
    );
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

          my ServerStatus $status = $servers{$server-name}.get-status<status> // SS-Unknown;

          given $status {
            when SS-Standalone {
              $servers-count++;
              if $found-standalone or $found-sharded or $found-replica {

                # cannot have more than one standalone servers
                $topology = TT-Unknown;
              }

              else {

                $found-standalone = True;
                $topology = TT-Single;
              }
            }

            when SS-Mongos {
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
            when SS-RSPrimary {
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

            when any( SS-RSSecondary, SS-RSArbiter, SS-RSOther, SS-RSGhost ) {
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
            } # when any()
          } # given $status
        } # for $servers.keys -> $server-name

        if $servers-count == 1 and $!uri-data<options><replicaSet>:!exists {
          $topology = TT-Single;
        }

        $!rw-sem.writer( 'topology', {
            $!topology-type = $topology;
            $!topology-set = True;
          }
        );

        info-message("Client topology type set to $topology");


#      } # writer block
#    ); # writer
  }

  #-----------------------------------------------------------------------------
  # Return number of servers
  method nbr-servers ( --> Int ) {

    self!check-discovery-process;
    $!rw-sem.reader( 'servers', {$!servers.elems;});
  }

  #-----------------------------------------------------------------------------
  # Called from thread above where Server object is created.
  method server-status ( Str:D $server-name --> ServerStatus ) {

    self!check-discovery-process;

    #! Wait until topology is set
    until $!rw-sem.reader( 'topology', { $!topology-set }) {
      sleep 0.5;
    }

    my Hash $h = $!rw-sem.reader(
      'servers', {
      my $x = $!servers{$server-name}:exists
              ?? $!servers{$server-name}.get-status
              !! {};
      $x;
    });

    my ServerStatus $sts = $h<status> // SS-Unknown;
    debug-message("server-status: '$server-name', $sts");
    $sts;
  }

  #-----------------------------------------------------------------------------
  method topology ( --> TopologyType ) {

    #! Wait until topology is set
    until $!rw-sem.reader( 'topology', { $!topology-set }) {
      sleep 0.5;
    }

    $!rw-sem.reader( 'topology', {$!topology-type});
  }

  #-----------------------------------------------------------------------------
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
  #-----------------------------------------------------------------------------

  #-----------------------------------------------------------------------------
  # Request specific servername
  multi method select-server ( Str:D :$servername! --> MongoDB::Server ) {

    # record the server selection start time. used also in debug message
    my Instant $t0 = now;

    self!check-discovery-process;

    my MongoDB::Server $selected-server;

    #! Wait until topology is set
    until $!rw-sem.reader( 'topology', { $!topology-set }) {
      sleep 0.5;
    }

    # find suitable servers by topology type and operation type
    repeat {

      $selected-server = $!rw-sem.reader( 'servers', {
#note "Servers: ", $!servers.keys;
#note "Request: $selected-servername";
          $!servers{$servername}:exists
                  ?? $!servers{$servername}
                  !! MongoDB::Server;
        }
      );

      last if ? $selected-server;
      sleep $!heartbeat-frequency-ms / 1000.0;
    } while ((now - $t0) * 1000) < $!server-selection-timeout-ms;

    debug-message("Searched for {(now - $t0) * 1000} ms");

    if ?$selected-server {
      info-message("Server '$selected-server.name()' selected");
    }

    else {
      warn-message("No suitable server selected");
    }

    $selected-server;
  }


#TODO pod doc
#TODO use read/write concern for selection
#TODO must break loop when nothing is found

  #-----------------------------------------------------------------------------
  # Read/write concern selection
  multi method select-server (
    BSON::Document :$read-concern is copy
    --> MongoDB::Server
  ) {

    $read-concern //= $!read-concern;
    my MongoDB::Server $selected-server;

    # record the server selection start time. used also in debug message
    my Instant $t0 = now;

    #! Wait until topology is set
    until $!rw-sem.reader( 'topology', { $!topology-set }) {
      sleep 0.5;
    }

    # find suitable servers by topology type and operation type
    repeat {

      my MongoDB::Server @selected-servers = ();
      my Hash $servers = $!rw-sem.reader( 'servers', {$!servers.clone});
      my TopologyType $topology = $!rw-sem.reader( 'topology', {$!topology-type});

      given $topology {
        when TT-Single {

          for $servers.keys -> $sname {
            $selected-server = $servers{$sname};
            my Hash $sdata = $selected-server.get-status;
            last if $sdata<status> ~~ SS-Standalone;
          }
        }

        when TT-ReplicaSetWithPrimary {

#TODO read concern
#TODO check replica set option in uri
          for $servers.keys -> $sname {
            $selected-server = $servers{$sname};
            my Hash $sdata = $selected-server.get-status;
            last if $sdata<status> ~~ SS-RSPrimary;
          }
        }

        when TT-ReplicaSetNoPrimary {

#TODO read concern
#TODO check replica set option in uri if SS-RSSecondary
          for $servers.keys -> $sname {
            my $s = $servers{$sname};
            my Hash $sdata = $s.get-status;
            @selected-servers.push: $s if $sdata<status> ~~ SS-RSSecondary;
          }
        }

        when TT-Sharded {

          for $servers.keys -> $sname {
            my $s = $servers{$sname};
            my Hash $sdata = $s.get-status;
            @selected-servers.push: $s if $sdata<status> ~~ SS-Mongos;
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
          for @selected-servers -> MongoDB::Server $svr {
            my Hash $svr-sts = $svr.get-status;
            $min-rtt-ms = $svr-sts<weighted-mean-rtt-ms>
              if $min-rtt-ms > $svr-sts<weighted-mean-rtt-ms>;
          }

          # select those servers falling in the window defined by the
          # minimum round trip time and minimum rtt plus a treshold
          for @selected-servers -> $svr {
            my Hash $svr-sts = $svr.get-status;
            $slctd-svrs.push: $svr if $svr-sts<weighted-mean-rtt-ms>
                                      <= ($min-rtt-ms + $!local-threshold-ms);
          }

          $selected-server = $slctd-svrs.pick;
        }
      }

      # done when a suitable server is found
      last if $selected-server.defined;

      # else wait for status and topology updates
#TODO synchronize with monitor times
      sleep $!heartbeat-frequency-ms / 1000.0;

    } while ((now - $t0) * 1000) < $!server-selection-timeout-ms;

    debug-message("Searched for {(now - $t0) * 1000} ms");

    if ?$selected-server {
      info-message("Server '$selected-server.name()' selected");
    }

    else {
      warn-message("No suitable server selected");
    }

    $selected-server;
  }

  #-----------------------------------------------------------------------------
  # Add server to todo list.
  method add-servers ( Array $hostspecs ) {

    trace-message("push $hostspecs[*] on todo list");
    $!rw-sem.writer( 'todo', { $!todo-servers.append: |$hostspecs; });
  }

  #-----------------------------------------------------------------------------
  # Check if background process is still running
  method !check-discovery-process ( ) {
    state $check-count = 0;

    if $!Background-discovery.status ~~ any(Broken|Kept) {
      # set if loop crashed
      $!repeat-discovery-loop = False;

      info-message(
        'Server discovery stopped: ' ~ (
          $!Background-discovery.status ~~ Broken
                         ?? $!Background-discovery.cause
                         !! $!Background-discovery.result
        )
      );

      # check every now and then for new servers after discovery-thread has
      # finished
      unless $!repeat-discovery-loop or $check-count++ % 5 {
        self!discover-servers;
      }
    }
  }

  #-----------------------------------------------------------------------------
  method !discover-servers ( --> Bool ) {

    my Bool $found-new-server = False;

    # always assume that there are changes
    $!rw-sem.writer( 'topology', { $!topology-set = False; } );

    # When the server discovery thread is still running $!repeat-discovery-loop
    # is still True. In this case we must get the data using semaphores.

    # Repeat when a server was found, there might be another one on the stack
    my Str $server-name;
    repeat {

      # Start processing when something is found in todo hash
      if $!repeat-discovery-loop {
        $server-name = $!rw-sem.writer(
          'todo', {
            ($!todo-servers.shift if $!todo-servers.elems) // Str;
          }
        );
      }

      else {
        $server-name = ($!todo-servers.shift if $!todo-servers.elems) // Str;
      }

      # check if a server name is popped from the todo stack
      if $server-name.defined {

        trace-message("Processing server $server-name");

        # check if from discovery-loop. if so do the safe access
        my Bool $server-processed;
        if $!repeat-discovery-loop {
          $server-processed = $!rw-sem.reader(
            'servers',
            { $!servers{$server-name}:exists; }
          );
        }

        else {
          $server-processed = $!servers{$server-name}:exists;
        }

        # Check if server was managed before
        if $server-processed {
          trace-message("Server $server-name already managed");
        }

        # new server
        else {

          # new server, re-examin the topology outcome, so block select-server
          # until after topology is calculated.
          $found-new-server = True;

          # create Server object
          my MongoDB::Server $server .= new( :client(self), :$server-name);

          # and start server monitoring
          $server.server-init($!heartbeat-frequency-ms);

          if $!repeat-discovery-loop {
            $!rw-sem.writer( 'servers', {$!servers{$server-name} = $server;});
          }

          else {
            $!servers{$server-name} = $server;
          }
        } # else
      } # if
    } while $server-name.defined; # repeat

    self.process-topology;
    $found-new-server;
  }

  #-----------------------------------------------------------------------------
  method database (
    Str:D $name, BSON::Document :$read-concern
    --> MongoDB::Database
  ) {

    my BSON::Document $rc =
       $read-concern.defined ?? $read-concern !! $!read-concern;

    MongoDB::Database.new( :client(self), :name($name), :read-concern($rc));
  }

  #-----------------------------------------------------------------------------
  method collection (
    Str:D $full-collection-name, BSON::Document :$read-concern
    --> MongoDB::Collection
  ) {
#TODO check for dot in the name

    my BSON::Document $rc =
       $read-concern.defined ?? $read-concern !! $!read-concern;

    ( my $db-name, my $cll-name) = $full-collection-name.split( '.', 2);

    my MongoDB::Database $db .= new(
      :client(self),
      :name($db-name),
      :read-concern($rc)
    );

    return $db.collection( $cll-name, :read-concern($rc));
  }

  #-----------------------------------------------------------------------------
  # Forced cleanup
  #
  # cleanup cannot be done in separate thread because everything must be cleaned
  # up before other tasks are performed. the client inserts new data while
  # removing them here. the last subtest of 110-client failed because of this.
  method cleanup ( ) {

    $!cleanup-started = True;

    # some timing to see if this cleanup can be improved
    my Instant $t0 = now;

    # stop loop and wait for exit
    if $!repeat-discovery-loop {
      $!repeat-discovery-loop = False;
      $!Background-discovery.result;
    }

    # Remove all servers concurrently. Shouldn't be many per client.
    $!rw-sem.writer(
      'servers', {

        for $!servers.values -> MongoDB::Server $server {
          if $server.defined {
            # Stop monitoring on server
            $server.cleanup;
            debug-message(
              "server '$server.name()' destroyed after {(now - $t0) * 1000.0} ms"
            );
          }
        }
      }
    );

    $!servers = Nil;
    $!todo-servers = Nil;

    debug-message("Client destroyed after {(now - $t0) * 1000.0} ms");

  }
}
