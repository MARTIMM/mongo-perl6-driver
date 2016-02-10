use v6;
use lib 't';
use Test-support;
use MongoDB::Server;
use Test;


#TODO Checks for windows environment

#-------------------------------------------------------------------------------
# Download mongodb binaries before testing on TRAVIS-CI. Version of mongo on
# Travis is still from the middle ages (2.4.12).
#
# Assume at first that mongod is in the users path, then we try to find a path
# to it depending on OS. If it can be found, use the precise path.
#
my $mongodb-server-path = 'mongod';

# On Travis-ci the path is known because I've put it there using the script
# install-mongodb.sh.
#
if ? %*ENV<TRAVIS> {
  $mongodb-server-path = "$*CWD/Travis-ci/MongoDB/mongod";
}

# On linuxes it should be in /usr/bin
#
elsif $*KERNEL.name eq 'linux' {
  if '/usr/bin/mongod'.IO ~~ :x {
    $mongodb-server-path = '/usr/bin/mongod';
  }
}

# On windows it should be in C:/Program Files/MongoDB/Server/*/bin if the
# user keeps the default installation directory.
#
elsif $*KERNEL.name eq 'win32' {
  for 2.6, 2.8 ... 10 -> $vn {
    my Str $path = "C:/Program Files/MongoDB/Server/$vn/bin/mongod.exe";
    if $path.IO ~~ :e {
      $mongodb-server-path = $path;
      last;
    }
  }
}

#-------------------------------------------------------------------------------
#
diag "\n\nSetting up involves initializing mongodb data files which takes time";

#-------------------------------------------------------------------------------
# Check directory Sandbox
#
mkdir( 'Sandbox', 0o700) unless 'Sandbox'.IO ~~ :d;

mkdir( 'Sandbox/Server1', 0o700) unless 'Sandbox/Server1'.IO ~~ :d;
mkdir( 'Sandbox/Server1/m.data', 0o700) unless 'Sandbox/Server1/m.data'.IO ~~ :d;

mkdir( 'Sandbox/Server2', 0o700) unless 'Sandbox/Server2'.IO ~~ :d;
mkdir( 'Sandbox/Server2/m.data', 0o700) unless 'Sandbox/Server2/m.data'.IO ~~ :d;

#`{{
  Test for usable port number
  According to https://en.wikipedia.org/wiki/List_of_TCP_and_UDP_port_numbers

  Dynamic, private or ephemeral ports

  The range 49152-65535 (2**15+2**14 to 2**16-1) contains dynamic or
  private ports that cannot be registered with IANA. This range is used
  for private, or customized services or temporary purposes and for automatic
  allocation of ephemeral ports.

  According to  https://en.wikipedia.org/wiki/Ephemeral_port

  Many Linux kernels use the port range 32768 to 61000.
  FreeBSD has used the IANA port range since release 4.6.
  Previous versions, including the Berkeley Software Distribution (BSD), use
  ports 1024 to 5000 as ephemeral ports.[2]

  Microsoft Windows operating systems through XP use the range 1025-5000 as
  ephemeral ports by default.
  Windows Vista, Windows 7, and Server 2008 use the IANA range by default.
  Windows Server 2003 uses the range 1025-5000 by default, until Microsoft
  security update MS08-037 from 2008 is installed, after which it uses the IANA
  range by default.
  Windows Server 2008 with Exchange Server 2007 installed has a default port
  range of 1025-60000.
  In addition to the default range, all versions of Windows since Windows 2000
  have the option of specifying a custom range anywhere within 1025-365535.
}}

# Search from port 65000 until the last of possible port numbers for a free
# port. this will be configured in the mongodb config file. At least one
# should be found here.
#
my $port-number1;
for 65000 ..^ 2**16 -> $p {
  my $s = IO::Socket::INET.new( :host('localhost'), :port($p));
  $s.close;

  CATCH {
    default {
      $port-number1 = $p;
      last;
    }
  }
}

my $port-number2;
for $port-number1 ^..^ 2**16 -> $p {
  my $s = IO::Socket::INET.new( :host('localhost'), :port($p));
  $s.close;

  CATCH {
    default {
      $port-number2 = $p;
      last;
    }
  }
}

ok $port-number1 >= 65000, "Portnumber for server1 $port-number1";
ok $port-number2 >= $port-number1, "Portnumber for server2 $port-number2";

# Save portnumber for later tests
#
spurt 'Sandbox/Server1/port-number', $port-number1;
spurt 'Sandbox/Server2/port-number', $port-number2;

# Generate mongodb config in Sandbox using YAML. Journalling is turned off
# for quicker startup.
#
my $config1 = qq:to/EOCNF/;

  systemLog:
    verbosity:                  0
    quiet:                      false
    traceAllExceptions:         true
  #  syslogFacility:             user
    path:                       $*CWD/Sandbox/Server1/m.log
    logAppend:                  true
    logRotate:                  rename
    destination:                file
    timeStampFormat:            iso8601-local
    component:
      accessControl:
        verbosity:              2
      command:
        verbosity:              0
      control:
        verbosity:              0
      geo:
        verbosity:              0
      index:
        verbosity:              0
      network:
        verbosity:              0
      query:
        verbosity:              0
      replication:
        verbosity:              0
      sharding:
        verbosity:              0
      storage:
        verbosity:              0
        journal:
          verbosity:            0
      write:
        verbosity:              0

  processManagement:
    fork:                       true
    pidFilePath:                $*CWD/Sandbox/Server1/m.pid

  net:
  #  bindIp:                     localhost
    port:                       $port-number1
    wireObjectCheck:            true
    http:
      enabled:                  false

  storage:
    dbPath:                     $*CWD/Sandbox/Server1/m.data
    journal:
      enabled:                  false
    directoryPerDB:             false

  EOCNF

spurt 'Sandbox/Server1/m.conf', $config1;

# Generate config for second server
#
my $config2 = $config1;
$config2 ~~ s:g/Server1/Server2/;
$config2 ~~ s:g/$port-number1/$port-number2/;
spurt 'Sandbox/Server2/m.conf', $config2;

# Generate mongodb config with authentication turned on
#
my $auth-config = qq:to/EOCNF/;

  security:
  #  keyFile:                    m.key-file
  #  clusterAuthMode:            keyFile
    authorization:              enabled

  setParameter:
    enableLocalhostAuthBypass:  false

  EOCNF

spurt 'Sandbox/Server1/m-auth.conf', $config1 ~ $auth-config;
spurt 'Sandbox/Server2/m-auth.conf', $config2 ~ $auth-config;

# Start mongodb
#
diag "Wait for servers to start up using port $port-number1 and $port-number2";
say "Starting \"$mongodb-server-path --config '$*CWD/Sandbox/Server*/m.conf'\"";
my Proc $proc1 = shell("$mongodb-server-path --config '$*CWD/Sandbox/Server1/m.conf'");
if $proc1.exitcode != 0 {
  spurt 'Sandbox/Server1/NO-MONGODB-SERVER', '' unless $proc1.exitcode == 0;
  plan 1;
  flunk('No database server started!');
  skip-rest('No database server started!');
  exit(0);
}

else {
  # Remove the file if still there
  #
  if 'Sandbox/Server1/NO-MONGODB-SERVER'.IO ~~ :e {
    unlink 'Sandbox/Server1NO-MONGODB-SERVER';
  }
}

my Proc $proc2 = shell("$mongodb-server-path --config '$*CWD/Sandbox/Server2/m.conf'");

if $proc2.exitcode != 0 {
  spurt 'Sandbox/Server2/NO-MONGODB-SERVER', '' unless $proc2.exitcode == 0;
  plan 1;
  flunk('No database server started!');
  skip-rest('No database server started!');
  exit(0);
}

else {
  # Remove the file if still there
  #
  if 'Sandbox/Server2/NO-MONGODB-SERVER'.IO ~~ :e {
    unlink 'Sandbox/Server1NO-MONGODB-SERVER';
  }
}

#-------------------------------------------------------------------------------
# Cleanup and close
#
done-testing();
exit(0);
