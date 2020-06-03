use v6;

use MongoDB::Log;

sub EXPORT { {
    '&add-send-to'                      => &add-send-to,
    '&modify-send-to'                   => &modify-send-to,
    '&drop-send-to'                     => &drop-send-to,
    '&drop-all-send-to'                 => &drop-all-send-to,


    '&trace-message'                    => &trace-message,
    '&debug-message'                    => &debug-message,
    '&info-message'                     => &info-message,
    '&warn-message'                     => &warn-message,
    '&error-message'                    => &error-message,
    '&fatal-message'                    => &fatal-message,

    'X::MongoDB'               => X::MongoDB,
  }
};

#------------------------------------------------------------------------------
unit package MongoDB:auth<github:MARTIMM>;

#------------------------------------------------------------------------------
constant SERVER-VERSION1 is export = '4.0.5';
constant SERVER-VERSION2 is export = '4.0.18';

#------------------------------------------------------------------------------
# wire versions
# See also https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#data-structures
constant clientMinWireVersion is export = 0;
constant clientMaxWireVersion is export = 7;

#------------------------------------------------------------------------------
# Client object topology types
# See also https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#data-structures

enum TopologyType is export <
  TT-Single TT-ReplicaSetNoPrimary TT-ReplicaSetWithPrimary
  TT-Sharded TT-Unknown TT-NotSet
>;

#------------------------------------------------------------------------------
# Status values of a Server.object
# See also https://github.com/mongodb/specifications/blob/master/source/server-discovery-and-monitoring/server-discovery-and-monitoring.rst#data-structures

enum ServerType is export <
  ST-Standalone ST-Mongos ST-PossiblePrimary ST-RSPrimary ST-RSSecondary
  ST-RSArbiter ST-RSOther ST-RSGhost ST-Unknown
>;

#------------------------------------------------------------------------------
# See also https://www.mongodb.com/blog/post/server-selection-next-generation-mongodb-drivers
# read concern mode values
#TODO pod doc arguments
enum ReadConcernModes is export <
  RCM-Primary RCM-Secondary RCM-Primary-preferred
  RCM-Secondary-preferred RCM-Nearest
>;

#------------------------------------------------------------------------------
# Constants. See http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-RequestOpcodes
enum WireOpcode is export (
  :OP-REPLY(1),
  :OP-MSG(1000), :OP-UPDATE(2001), :OP-INSERT(2002),
  :OP-RESERVED(2003), :OP-QUERY(2004), :OP-GET-MORE(2005),
  :OP-DELETE(2006), :OP-KILL-CURSORS(2007),
);

#------------------------------------------------------------------------------
# Query flags
enum QueryFindFlags is export (
  :C-NO-FLAGS(0x00), :C-QF-RESERVED(0x01),
  :C-QF-TAILABLECURSOR(0x02), :C-QF-SLAVEOK(0x04),
  :C-QF-OPLOGREPLAY(0x08), :C-QF-NOCURSORTIMOUT(0x10), :C-QF-AWAITDATA(0x20),
  :C-QF-EXHAUST(0x40), :C-QF-PORTAIL(0x80),
);

#------------------------------------------------------------------------------
# Response flags
enum ResponseFlags is export (
  :RF-CURSORNOTFOUND(0x01), :RF-QUERYFAILURE(0x02),
  :RF-SHARDCONFIGSTALE(0x04), :RF-AWAITCAPABLE(0x08),
);

#------------------------------------------------------------------------------
# Socket values
constant MAX-SOCKET-UNUSED-OPEN is export = 900; # Quarter of an hour unused

#------------------------------------------------------------------------------
# Server defaults
constant C-LOCALTHRESHOLDMS is export = 15;
constant C-SERVERSELECTIONTIMEOUTMS is export = 30_000;
constant C-HEARTBEATFREQUENCYMS is export = 10_000;

#------------------------------------------------------------------------------
# Client defaults
constant C-SMALLEST-MAX-STALENEST-SECONDS = 90;

#------------------------------------------------------------------------------
# User admin defaults
constant C-PW-LOWERCASE is export = 0;
constant C-PW-UPPERCASE is export = 1;
constant C-PW-NUMBERS is export = 2;
constant C-PW-OTHER-CHARS is export = 3;

constant C-PW-MIN-UN-LEN is export = 6;
constant C-PW-MIN-PW-LEN is export = 6;

#------------------------------------------------------------------------------
# Other types

# See also https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers
subset PortType of Int is export where 0 < $_ <= 65535;

# Helper constraints when module cannot be loaded(use)
subset ClientType is export where .^name eq 'MongoDB::Client';
subset DatabaseType is export where .^name eq 'MongoDB::Database';
subset CollectionType is export where .^name eq 'MongoDB::Collection';
subset ServerClassType is export where .^name eq 'MongoDB::Server';
subset SocketType is export where .^name eq 'MongoDB::Server::Socket';

#------------------------------------------------------------------------------
#signal(Signal::SIGTERM).tap: {say "Hi"; die "Stopped by user"};

#------------------------------------------------------------------------------
sub mongodb-driver-version ( --> Version ) is export {
  MongoDB.^ver;
}

#------------------------------------------------------------------------------
sub mongodb-driver-author ( --> Str ) is export {
  MongoDB.^auth;
}
