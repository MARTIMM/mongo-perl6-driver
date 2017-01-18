use v6.c;
use MongoDB::Log :ALL;

#`{{
sub EXPORT { {
#    '&set-exception-process-level'      => &set-exception-process-level,
#    '&set-exception-processing'         => &set-exception-processing,
#    '&set-logfile'                      => &set-logfile,
#    '&open-logfile'                     => &open-logfile,

    '&add-send-to'                      => &add-send-to,
    '&drop-send-to'                     => &drop-send-to,

    '&trace-message'                    => &trace-message,
    '&debug-message'                    => &debug-message,
    '&info-message'                     => &info-message,
    '&warn-message'                     => &warn-message,
    '&error-message'                    => &error-message,
    '&fatal-message'                    => &fatal-message,
  }
};
}}

#-------------------------------------------------------------------------------
unit package MongoDB:ver<0.36.1>:auth<https://github.com/MARTIMM>;

#-----------------------------------------------------------------------------
# Client object topology types
enum TopologyType is export <
  SINGLE-TPLGY
  REPLSET-WITH-PRIMARY-TPLGY REPLSET-NO-PRIMARY-TPLGY
  SHARDED-TPLGY UNKNOWN-TPLGY
>;

#-----------------------------------------------------------------------------
# Status values of a Server.object
enum ServerStatus is export <
  UNKNOWN-SERVER NON-EXISTENT-SERVER DOWN-SERVER RECOVERING-SERVER
  REJECTED-SERVER GHOST-SERVER

  REPLICA-PRE-INIT REPLICASET-PRIMARY REPLICASET-SECONDARY
  REPLICASET-ARBITER

  SHARDING-SERVER MASTER-SERVER SLAVE-SERVER
>;

#-----------------------------------------------------------------------------
# Constants. See http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-RequestOpcodes
enum WireOpcode is export (
  :OP-REPLY(1),
  :OP-MSG(1000), :OP-UPDATE(2001), :OP-INSERT(2002),
  :OP-RESERVED(2003), :OP-QUERY(2004), :OP-GET-MORE(2005),
  :OP-DELETE(2006), :OP-KILL-CURSORS(2007),
);

#-----------------------------------------------------------------------------
# Query flags
enum QueryFindFlags is export (
  :C-NO-FLAGS(0x00), :C-QF-RESERVED(0x01),
  :C-QF-TAILABLECURSOR(0x02), :C-QF-SLAVEOK(0x04),
  :C-QF-OPLOGREPLAY(0x08), :C-QF-NOCURSORTIMOUT(0x10), :C-QF-AWAITDATA(0x20),
  :C-QF-EXHAUST(0x40), :C-QF-PORTAIL(0x80),
);

#-----------------------------------------------------------------------------
# Response flags
enum ResponseFlags is export (
  :RF-CURSORNOTFOUND(0x01), :RF-QUERYFAILURE(0x02),
  :RF-SHARDCONFIGSTALE(0x04), :RF-AWAITCAPABLE(0x08),
);

#-----------------------------------------------------------------------------
# Socket values
constant MAX-SOCKET-UNUSED-OPEN is export = 900; # Quarter of an hour unused

#-----------------------------------------------------------------------------
# Other types

# See also https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers
subset PortType of Int is export where 0 < $_ <= 65535;

# Helper constraints when module cannot be loaded(use)
subset ClientType is export where .^name eq 'MongoDB::Client';
subset DatabaseType is export where .^name eq 'MongoDB::Database';
subset CollectionType is export where .^name eq 'MongoDB::Collection';
subset ServerType is export where .^name eq 'MongoDB::Server';
subset SocketType is export where .^name eq 'MongoDB::Socket';

#-----------------------------------------------------------------------------
#
signal(Signal::SIGTERM).tap: {say "Hi"; die "Stopped by user"};

#-----------------------------------------------------------------------------
sub mongodb-driver-version ( --> Version ) is export {
  MongoDB.^ver;
}

#-----------------------------------------------------------------------------
sub mongodb-driver-author ( --> Str ) is export {
  MongoDB.^auth;
}
