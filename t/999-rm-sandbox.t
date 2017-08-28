use v6.c;
use lib 't';

use Test;
use Test-support;
use MongoDB;

#-------------------------------------------------------------------------------
drop-send-to('mongodb');
drop-send-to('screen');
#modify-send-to( 'screen', :level(MongoDB::MdbLoglevels::Debug));
info-message("Test $?FILE start");

my MongoDB::Test-support $ts .= new;

#-----------------------------------------------------------------------------
  try {
    ok $ts.server-control.stop-mongod('s1'),
       "Server s1 is stopped";
    CATCH {
      when X::MongoDB {
        like .message, /:s exited unsuccessfully/,
             "Server 's1r' already down";
      }
    }
  }
}

throws-like { $ts.server-control.stop-mongod('s1') },
            X::MongoDB, :message(/:s exited unsuccessfully/);

$ts.cleanup-sandbox();

#-----------------------------------------------------------------------------
# Cleanup and close
info-message("Test $?FILE start");
sleep .2;
drop-all-send-to();
done-testing();
exit(0);
