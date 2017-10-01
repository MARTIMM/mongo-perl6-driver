use v6;

use Terminal::ANSIColor;
use Log::Async;

#------------------------------------------------------------------------------
package MongoDB:auth<github:MARTIMM> {

  enum MdbLoglevels << :Trace(TRACE) :Debug(DEBUG) :Info(INFO)
                       :Warn(WARNING) :Error(ERROR) :Fatal(FATAL)
                    >>;

  enum SendSetup < LOGOUTPUT LOGLEVEL LOGCODE >;

  #----------------------------------------------------------------------------
  class Log is Log::Async {

    has Hash $!send-to-setup;

    #--------------------------------------------------------------------------
    submethod BUILD ( ) {

      $!send-to-setup = {};
    }

    #--------------------------------------------------------------------------
    # add or overwrite a channel
    method add-send-to (
      Str:D $key, MdbLoglevels :$min-level = Info, Code :$code, :$to, Str :$pipe
    ) {

      my $output;# = $*ERR;
      if ? $pipe {
        my Proc $p = shell $pipe, :in;
        $output = $p.in;
#note "Ex code: $p.exitcode()";
#        if $p.exitcode > 0 {
#          $p.in.close;
#          die "error opening pipe to '$pipe'" if $p.exitcode > 0;
#        }
      }

      else {
        $output = $to // $*ERR;
      }

      # check if I/O channel is other than stdout or stderr. If so, close them.
      if $!send-to-setup{$key}:exists
         and !($!send-to-setup{$key}[LOGOUTPUT] === $*OUT)
         and !($!send-to-setup{$key}[LOGOUTPUT] === $*ERR) {

        $!send-to-setup{$key}[LOGOUTPUT].close;
      }

      # define the entry [ output channel, error level, code to run]
      $!send-to-setup{$key} = [ $output, (* >= $min-level), $code];
      self!start-send-to;
    }

    #--------------------------------------------------------------------------
    # modify a channel
    method modify-send-to (
      Str $key, :$level, Code :$code,
      Any :$to is copy, Str :$pipe
    ) {

      if $!send-to-setup{$key}:!exists {
        note "key $key not found";
        return;
      }

      if ? $pipe {
        my Proc $p = shell $pipe, :in;
        $to = $p.in;
#        die "error opening pipe to $pipe" if $p.exitcode > 0;
      }

      # prepare array to replace for new values
      my Array $psto = $!send-to-setup{$key} // [];

      # check if I/O channel is other than stdout or stderr. If so, close them.
      if ?$psto[LOGOUTPUT]
         and !($psto[LOGOUTPUT] === $*OUT)
         and !($psto[LOGOUTPUT] === $*ERR) {
        $psto[LOGOUTPUT].close;
      }

      $psto[LOGOUTPUT] = $to if ? $to;
      $psto[LOGLEVEL] = (* >= $level) if ? $level;
      $psto[LOGCODE] = $code if ? $code;
      $!send-to-setup{$key} = $psto;

      self!start-send-to;
    }

    #--------------------------------------------------------------------------
    # drop channel
    method drop-send-to ( Str:D $key ) {

      if $!send-to-setup{$key}:exists {
        my Array $psto = $!send-to-setup{$key}:delete;

        # check if I/O channel is other than stdout or stderr. If so, close them.
        if ?$psto[LOGOUTPUT]
        and !($psto[LOGOUTPUT] === $*OUT)
        and !($psto[LOGOUTPUT] === $*ERR) {
          $psto[LOGOUTPUT].close;
        }
      }

      self!start-send-to;
    }

    #--------------------------------------------------------------------------
    # drop all channel
    method drop-all-send-to ( ) {

      self.close-taps;

      for $!send-to-setup.keys -> $key {
        self.drop-send-to($key);
      }

      $!send-to-setup = {};
    }

    #--------------------------------------------------------------------------
    # start channels
    method !start-send-to ( ) {

      self.close-taps;
      for $!send-to-setup.keys -> $k {
        if ? $!send-to-setup{$k}[LOGCODE] {
          logger.send-to(
            $!send-to-setup{$k}[LOGOUTPUT],
            :code($!send-to-setup{$k}[LOGCODE]),
            :level($!send-to-setup{$k}[LOGLEVEL])
          );
        }

        else {
          logger.send-to(
            $!send-to-setup{$k}[LOGOUTPUT],
            :level($!send-to-setup{$k}[LOGLEVEL])
          );
        }
      }
    }

    #--------------------------------------------------------------------------
    # send-to method
    multi method send-to ( IO::Handle:D $fh, Code:D :$code!, |args ) {

      logger.add-tap( -> $m { $m<fh> = $fh; $code($m); }, |args);
    }

    #--------------------------------------------------------------------------
    # overload log method
    method log (
      Str:D :$msg, Loglevels:D :$level,
      DateTime :$when = DateTime.now.utc,
      Code :$code
    ) {

      my Hash $m;
      if ? $code {
        $m = $code( :$msg, :$level, :$when);
      }

      else {
        $m = { :$msg, :$level, :$when };
      }

#note "\n$m";
      ( start $.source.emit($m) ).then( {
#          say LogLevel::TRACE;
#          say LogLevel::Trace;
#          say MongoDB::Log::Trace;
#          say .perl;
          note $^p.cause unless $^p.status == Kept
        }
      );
    }
  }
}

#------------------------------------------------------------------------------
set-logger(MongoDB::Log.new());

#------------------------------------------------------------------------------
class X::MongoDB is Exception {
  has Str $.message;            # Error text and error code are data mostly
  has Str $.method;             # Method or routine name
  has Int $.line;               # Line number where Message is called
  has Str $.file;               # File in which that happened
}

#------------------------------------------------------------------------------
# preparations of code to be provided to log()
sub search-callframe ( $type --> CallFrame ) {

  # skip callframes for
  # 0  search-callframe(method)
  # 1  log(method)
  # 2  send-to(method)
  # 3  -> m { ... }
  # 4  *-message(sub) helper functions
  #
  my $fn = 4;
  while my CallFrame $cf = callframe($fn++) {

    # end loop with the program that starts on line 1 and code object is
    # a hollow shell.
    if ?$cf and $cf.line == 1  and $cf.code ~~ Mu {

      $cf = Nil;
      last;
    }

    # cannot pass sub THREAD-ENTRY either
    if ?$cf and $cf.code.^can('name') and $cf.code.name eq 'THREAD-ENTRY' {

      $cf = Nil;
      last;
    }

    if ?$cf and $type ~~ Sub
       and $cf.code.name ~~ m/[trace|debug|info|warn|error|fatal] '-message'/ {

      last;
    }

    # try to find a better place instead of dispatch, BUILDALL etc:...
    next if $cf.code ~~ $type and $cf.code.name ~~ m/dispatch/;
    last if $cf.code ~~ $type;
  }

  $cf
}

#------------------------------------------------------------------------------
# log code with stack frames
my Code $log-code-cf = sub (
  Str:D :$msg, Any:D :$level,
  DateTime :$when = DateTime.now.utc
  --> Hash
) {
  my CallFrame $cf;
  my Str $method = '';        # method or routine name
  my Int $line = 0;           # line number where Message is called
  my Str $file = '';          # file in which that happened

  $cf = search-callframe(Method);
  $cf = search-callframe(Submethod)     unless $cf.defined;
  $cf = search-callframe(Sub)           unless $cf.defined;
  $cf = search-callframe(Block)         unless $cf.defined;

  if $cf.defined {
    $line = $cf.line.Int // 1;
    $file = $cf.file // '';
    $file ~~ s/$*CWD/\./;
    $method = $cf.code.name // '';
  }

  hash(
    :thid($*THREAD.id),
    :$line, :$file, :$method,
    :$msg, :$level, :$when,
  )
}

#------------------------------------------------------------------------------
# log code without stack frames
my Code $log-code = sub (
  Str:D :$msg, Any:D :$level,
  DateTime :$when = DateTime.now.utc
  --> Hash
) {
  my Str $method = '';        # method or routine name
  my Int $line = 0;           # line number where Message is called
  my Str $file = '';          # file in which that happened

  hash(
    :thid($*THREAD.id),
    :$line, :$file, :$method,
    :$msg, :$level, :$when,
  )
}

#------------------------------------------------------------------------------
sub trace-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Trace), :code($log-code));
}

#------------------------------------------------------------------------------
sub debug-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Debug), :code($log-code));
}

#------------------------------------------------------------------------------
sub info-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Info), :code($log-code));
}

#------------------------------------------------------------------------------
sub warn-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Warn), :code($log-code-cf));
}

#------------------------------------------------------------------------------
sub error-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Error), :code($log-code-cf));
}

#------------------------------------------------------------------------------
sub fatal-message ( Str $msg ) is export {
  logger.log( :$msg, :level(MongoDB::Fatal), :code($log-code-cf));
  sleep 0.5;
  die X::MongoDB.new( :message($msg));
}

#------------------------------------------------------------------------------
# preparations of code to be provided to send-to()
# loglevels enum counts from 1 so 0 has placeholder PH0
my Array $sv-lvls = [< PH0 T D I W E F>];
my Array $clr-lvls = [
  'PH1',
  '0,150,150',
  '0,150,255',
  '0,200,0',
  '200,200,0',
  'bold white on_255,0,0',
  'bold white on_255,0,255'
];

my Code $code = sub ( $m ) {
  my Str $dt-str = $m<when>.Str;
  $dt-str ~~ s:g/ <[T]> / /;
  $dt-str ~~ s:g/ <[Z]> //;

  my IO::Handle $fh = $m<fh>;
  if $fh ~~ any( $*OUT, $*ERR) {
    $fh.print: color($clr-lvls[$m<level>]);
  }

  $fh.print( (
      [~] $dt-str,
      ' [' ~ $sv-lvls[$m<level>] ~ ']',
      ? $m<thid> ?? " $m<thid>.fmt('%2d')" !! '',
      ? $m<msg> ?? ": $m<msg>" !! '',
      ? $m<file> ?? ". At $m<file>" !! '',
      ? $m<line> ?? ':' ~ $m<line> !! '',
      ? $m<method> ?? " in $m<method>" ~ ($m<method> eq '<unit>' ?? '' !! '()')
                   !! '',
    )
  );

  $fh.print(color('reset')) if $fh ~~ any( $*OUT, $*ERR);
  $fh.print("\n");
};

#------------------------------------------------------------------------------
sub add-send-to ( |c ) is export { logger.add-send-to( |c, :$code); }
sub modify-send-to ( |c ) is export { logger.modify-send-to( |c, :$code); }
sub drop-send-to ( |c ) is export { logger.drop-send-to(|c); }
sub drop-all-send-to ( ) is export { logger.drop-all-send-to(); }

#------------------------------------------------------------------------------
# activate some channels. Display messages only on error and fatal to the screen
# and all messages of type info, warning, error and fatal to a file MongoDB.log
add-send-to( 'screen', :to($*ERR), :min-level(MongoDB::MdbLoglevels::Error));
add-send-to(
  'mongodb',
  :pipe('sort >> MongoDB.log'),
  :min-level(MongoDB::MdbLoglevels::Info)
);
