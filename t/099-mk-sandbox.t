use v6;
use lib 't';

use Test;
use Test-support;

use MongoDB;
use MongoDB::Server::Control;

#-------------------------------------------------------------------------------
drop-send-to('mongodb');
drop-send-to('screen');
#modify-send-to( 'screen', :level(MongoDB::MdbLoglevels::Debug));
info-message("Test $?FILE start");

my MongoDB::Test-support $ts .= new;

#-------------------------------------------------------------------------------
for $ts.server-range -> $server-number {
  try {
    ok $ts.server-control.start-mongod("s$server-number"),
       "Server $server-number started";
    CATCH {
      when X::MongoDB {
        like .message, /:s exited unsuccessfully /,
             "Server 's$server-number' already started";
      }
    }
  }
}

throws-like { $ts.server-control.start-mongod('s1') },
            X::MongoDB, :message(/:s exited unsuccessfully/);

#-------------------------------------------------------------------------------
# Cleanup and close
#info-message("Test $?FILE stop");
done-testing();
exit(0);
