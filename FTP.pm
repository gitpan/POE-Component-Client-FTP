# POE::Component::Client::FTP
#
# Author      : Michael Ching
# Email       : michaelc@wush.net
# Created     : May 15, 2002
# Description : An FTP client for POE

package POE::Component::Client::FTP;

use strict;
use warnings;
use Carp;
use vars qw($VERSION $poe_kernel);

$VERSION = 0.02;

use POE qw( Wheel::SocketFactory Wheel::ReadWrite Filter::Stream );
use Socket;

# use Data::Dumper;

sub DEBUG () { 0 }
sub EOL   () { "\015\012" }

# tells the dispatcher which states support which events
my $state_map = 
  { _init  => { "_start"        => \&do_init_start,
		"cmd_connected" => \&handler_init_connected,
		"success"       => \&handler_init_success,
	      },

    _stop  => { "_start" => \&do_stop 
	      },

    login  => { "login"        => \&do_login_send_username,
		"intermediate" => \&do_login_send_password,
		"success"      => \&handler_login_success,
		"failure"      => \&handler_login_failure
	      },

    global => { "cmd_input" => \&handler_cmd_input,
		"cmd_error" => \&handler_cmd_error,
	      },

    ready  => { "_start" => \&dequeue_event,
		rename   => \&do_rename,
		put      => \&do_put,

		map ( { $_ => \&do_simple_command }
		      qw{ cd cdup delete mdtm mkdir noop
			  pwd rmdir site size type quit } 
		    ),

		map ( { $_ => \&do_complex_command }
		      qw{ dir ls get }
		    ),
	      },

    put => { data_connected     => \&handler_put_connected,
	     data_connect_error => \&handler_complex_connect_error,
	     data_flush         => \&handler_put_kill_socket,
	     success            => \&handler_put_success,
	     preliminary        => \&handler_put_preliminary,
	     failure            => \&handler_put_failure,
	     data_error         => \&handler_put_data_error,
	     put_data           => \&do_put_data,
	     put_close          => \&do_put_close
	   },

    rename => { "intermediate" => \&handler_rename_intermediate,
		"success"      => \&handler_rename_success,
		"failure"      => \&handler_rename_failure
	      },

    default_simple  => { "success" => \&handler_simple_success,
			 "failure" => \&handler_simple_failure
		       },

    default_complex => { data_connected     => \&handler_complex_connected,
			 data_connect_error => \&handler_complex_connect_error,
			 preliminary        => \&handler_complex_preliminary,
			 success            => \&handler_complex_success,
			 failure            => \&handler_complex_failure,
			 data_input         => \&handler_complex_list_data,
			 data_error         => \&handler_complex_list_error
		       },
  };

# translation from posted signals to ftp commands
my %command_map  = ( MKDIR => "MKD", 
		     RMDIR => "RMD",
			 
		     LS  => "LIST",
		     DIR => "NLST",
		     GET => "RETR",

		     PUT => "STOR",
		   );

# create a new POE::Component::Client::FTP object
sub spawn {
  my $class = shift;
  my $sender = $poe_kernel->get_active_session;
  
  croak "$class->spawn requires an event number of argument" if @_ & 1;
  
  my %params = @_;
  
  my $alias = delete $params{Alias};
  croak "$class->spawn requires an alias to start" unless defined $alias;
  
  my $user = delete $params{Username};
  my $pass = delete $params{Password};

  my $local_addr = delete $params{LocalAddr};
  my $local_port = delete $params{LocalPort};

  my $remote_addr = delete $params{RemoteAddr};
  croak "$class->spawn requires a RemoteAddr parameter"
    unless defined $remote_addr;

  my $remote_port = delete $params{RemotePort};
  $remote_port = 21 unless defined $remote_port;
  
  my $timeout = delete $params{Timeout};
  $timeout = 120 unless defined $timeout;
  
  my $blocksize = delete $params{BlockSize};
  $blocksize = 10240 unless defined $blocksize;
  
  my $events = delete $params{Events};
  $events = [] unless defined $events and ref( $events ) eq 'ARRAY';
  my %register;
  for my $opt ( @$events ) {
    if ( ref $opt eq 'HASH' ) {
      @register{keys %$opt} = values %$opt;
    } else {
      $register{$opt} = $opt;
    }
  }

  # Make sure the user didn't make a typo on parameters
  carp "Unknown parameters: ", join( ', ', sort keys %params )
    if keys %params;

  POE::Session->create ( 
    inline_states => map_all($state_map, \&dispatch),

    heap => {
      alias           => $alias,
      user            => $user,
      pass            => $pass,
      local_addr      => $local_addr,
      local_port      => $local_port,
      remote_addr     => $remote_addr,
      remote_port     => $remote_port,
      timeout         => $timeout,
      blocksize       => $blocksize,

      cmd_sock_wheel  => undef,
      cmd_rw_wheel    => undef,

      data_sock_wheel => undef,
      data_rw_wheel   => undef,
      data_sock_port  => 0,
      data_suicidal   => 0,

      state           => "_init",
      queue           => [ ],

      stack           => [ [ 'init' ] ],
      event           => [ ],

      complex_stack   => [ ],

      events          => { $sender => \%register }
    }
  );
}

# connect to address specified during spawn
sub do_init_start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  # connect to command port
  $heap->{cmd_sock_wheel} = POE::Wheel::SocketFactory->new(
    SocketDomain   => AF_INET,
    SocketType     => SOCK_STREAM,
    SocketProtocol => 'tcp',
    RemotePort     => $heap->{remote_port},
    RemoteAddress  => $heap->{remote_addr},
    SuccessEvent   => 'cmd_connected',
    FailureEvent   => 'cmd_connect_error'
  );

  $kernel->alias_set( $heap->{alias} );
}

# try to clean up
# client responsibility to ensure things are all complete
sub do_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  delete $heap->{cmd_rw_wheel};
  delete $heap->{cmd_sock_wheel};
  delete $heap->{data_rw_wheel};
  delete $heap->{data_sock_wheel};

  $kernel->alias_remove( $heap->{alias} );
}

# server responses on command connection
sub handler_cmd_input {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  
  warn "< $input" if DEBUG;

  my $coderef;
  
  my $major = substr($input, 0, 1);

  if ($major == 1) {
    # 1yz   Positive Preliminary reply
    
    $coderef = $state_map->{ $heap->{state} }{preliminary};
  }
  elsif ($major == 2) {
    # 2yz   Positive Completion reply

    $coderef = $state_map->{ $heap->{state} }{success};
   
    # if it is "nnn-" then it is a multipart message
    # "nnn " marks the final message for an action
    if ($input =~ /^\d{3} /) {
      $heap->{event} = pop( @{$heap->{stack}} ) || ['none', {}];
    }
  }
  elsif ($major == 3) {
    # 3yz   Positive Intermediate reply

    $coderef = $state_map->{ $heap->{state} }{intermediate};

    if ($input =~ /^\d{3} /) {
      $heap->{event} = pop( @{$heap->{stack}} ) || ['none', {}];
    }
  }
  else {
     # 4yz   Transient Negative Completion reply
     # 5yz   Permanent Negative Completion reply

    $coderef = $state_map->{ $heap->{state} }{failure};

    if ($input =~ /^\d{3} /) {
      $heap->{event} = pop( @{$heap->{stack}} ) || ['none', {}];
    }
  }

  &{ $coderef }(@_) if $coderef;
}


# command connection closed
sub handler_cmd_error {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  goto_state("stop");
}

## state specific

## rename state

# initiate multipart rename command
# uses the complex_stack to remember what to do next
sub do_rename {
  my ($kernel, $heap, $event, $fr, $to) = @_[KERNEL, HEAP, STATE, ARG0, ARG1];

  goto_state("rename");

  $heap->{complex_stack} = [ "RNTO", $to ];
  command( [ "RNFR", $fr ] );
}

# successful RNFR
sub handler_rename_intermediate {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line = substr($input, 4);
  
  send_event( "rename_partial", 
	      $status, $line, 
	      $heap->{event}->[1] );

  command( $heap->{complex_stack} );
}

# successful RNTO
sub handler_rename_success {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line = substr($input, 4);
  
  send_event( "rename",
	      $status, $line, 
	      $heap->{event}->[1] );

  delete $heap->{complex_stack};
  goto_state("ready");
}

# failed RNFR or RNTO
sub handler_rename_failure {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line   = substr($input, 4);
  
  send_event( "rename_error", 
	      $status, $line, 
	      $heap->{event}->[1] );

  delete $heap->{complex_stack};
  goto_state("ready");
}

# initiate a STOR command
sub do_put {
  my ($kernel, $heap, $event) = @_[KERNEL, HEAP, STATE];

  goto_state("put");

  $heap->{complex_stack} = [ $event, @_[ARG0..$#_] ];
  
  command("PASV");
}

# data connection made
sub handler_put_connected {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];
  
  $heap->{data_rw_wheel} = POE::Wheel::ReadWrite->new(
    Handle       => $socket,
    Filter       => POE::Filter::Stream->new(),
    InputEvent   => 'data_input',
    ErrorEvent   => 'data_error',
    FlushedEvent => 'data_flush'
  );
  command($heap->{complex_stack});
}

# socket flushed, see if socket can be closed
sub handler_put_kill_socket {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  warn "data flushed" if DEBUG;
  if ($heap->{data_suicidal}) {
    warn "killing suicidal socket" if DEBUG;
    
    delete $heap->{data_sock_wheel};
    delete $heap->{data_rw_wheel};
    $heap->{data_suicidal} = 0;

    send_event("put_closed", 
	       $heap->{complex_stack}->[1]);
    goto_state("ready");
  }
}

# server acknowledged data connection
sub handler_put_preliminary {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line   = substr($input, 4);

  send_event( "put_ready", $status, $line,
	      $heap->{complex_stack}->[1] );
}

# server acknowledged data connection closed
sub handler_put_success {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  # if its a data connection success, use the default handler to accept it
  &handler_complex_success;

  # if not, then its in response to the STOR
  if ($heap->{event}->[0] ne "PASV") {
    my $status = substr($input, 0, 3);
    my $line   = substr($input, 4);
    
    send_event( "put", $status, $line,
		$heap->{complex_stack}->[1] );
  }
}

# server responded failure
sub handler_put_failure {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  delete $heap->{data_sock_wheel};
  delete $heap->{data_rw_wheel};

  my $status = substr($input, 0, 3);
  my $line   = substr($input, 4);

  send_event( "put_error", $status, $line,
	      $heap->{complex_stack}->[1] );
  goto_state("ready");
}

# remote end closed data connection
sub handler_put_data_error {
  my ($kernel, $heap, $error) = @_[KERNEL, HEAP, ARG0];

  delete $heap->{data_sock_wheel};
  delete $heap->{data_rw_wheel};

  send_event( "put_error", $error, 
	      $heap->{complex_stack}->[1] );
  goto_state("ready");
}

# client sending data for us to print to the STOR
sub do_put_data {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  warn "put: $input" if DEBUG;

  $heap->{data_rw_wheel}->put($input);
}

# client request to end STOR command
sub do_put_close { 
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  warn "setting suicidal on" if DEBUG;

  $heap->{data_suicidal} = 1;
}

## login state

# connection established, create a rw wheel
sub handler_init_connected {
    my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

    $heap->{cmd_rw_wheel} = POE::Wheel::ReadWrite->new(
	Handle     => $socket,
        Filter     => POE::Filter::Line->new( Literal => EOL ),
        InputEvent => 'cmd_input',
        ErrorEvent => 'cmd_error'
    );
}

# wheel established, log in if we can
sub handler_init_success {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  send_event('connected');
  goto_state("login");
  
  if ( defined $heap->{user} and defined $heap->{pass} ) {
    $kernel->yield("login");
  }
}

# login using parameters specified during spawn or passed in now
sub do_login_send_username {
  my ($kernel, $heap, $user, $pass) = @_[KERNEL, HEAP, ARG0 .. ARG1];
  
  $heap->{user} = $user unless defined $heap->{user};
  croak "No username defined in login" unless defined $heap->{user};
  $heap->{pass} = $pass unless defined $heap->{pass};
  croak "No password defined in login" unless defined $heap->{pass};
  
  command( [ 'USER', $heap->{user} ] );
  delete $heap->{user};
}

# username accepted
sub do_login_send_password {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
   
  command( [ 'PASS', $heap->{pass} ] );
  delete $heap->{pass};
}

sub handler_login_success {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  
  send_event("authenticated");
  goto_state("ready");
}

## default_simple state

# simple commands simply involve a command and one or more responses
sub do_simple_command {
  my ($kernel, $heap, $event) = @_[KERNEL, HEAP, STATE];

  goto_state("default_simple");

  command( [ $event, @_[ARG0..$#_] ] );
}

# end of response section will be marked by "\d{3} " whereas multipart
# messages will be "\d{3}-"
sub handler_simple_success {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line = substr($input, 4);
  
  send_event( lc $heap->{event}->[0], 
	      $status, $line, 
	      $heap->{event}->[1] );

  if ($input =~ /\d{3} /) {
    goto_state("ready");
  }
}

# server response for failure
sub handler_simple_failure {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line = substr($input, 4);
  
  send_event( lc $heap->{event}->[0] . "_error", 
	      $status, $line, 
	      $heap->{event}->[1] );

  goto_state("ready");
}

## default_complex state

# complex commands are those which require a data connection
sub do_complex_command {
  my ($kernel, $heap, $event) = @_[KERNEL, HEAP, STATE];

  goto_state("default_complex");

  $heap->{complex_stack} = [ $event, @_[ARG0..$#_] ];
  
  command("PASV");
}

# use the server response only for data connection establishment
# we will know when the command is actually done when the server
# terminates the data connection
sub handler_complex_success {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  if ($heap->{event}->[0] eq "PASV") {
    
    my (@ip, @port);
    (@ip[0..3], @port[0..1]) = $input =~ /(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)/;
    my $ip = join '.', @ip;
    my $port = $port[0]*256 + $port[1];
   
    $heap->{data_sock_wheel} = POE::Wheel::SocketFactory->new(
      SocketDomain   => AF_INET,
      SocketType     => SOCK_STREAM,
      SocketProtocol => 'tcp',
      RemotePort     => $port,
      RemoteAddress  => $ip,
      SuccessEvent   => 'data_connected',
      FailureEvent   => 'data_connect_error'
    );
  }
}

# server response for failure
sub handler_complex_failure {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];

  my $status = substr($input, 0, 3);
  my $line   = substr($input, 4);

  send_event( $heap->{complex_stack}->[0] . "_error", 
	      $status, $line, 
	      $heap->{complex_stack}->[1] );

  delete $heap->{data_sock_wheel};
  delete $heap->{data_rw_wheel};

  goto_state("ready");
}

# connection announced by server
sub handler_complex_preliminary {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  send_event( $heap->{complex_stack}->[0] . "_begin",
	      $heap->{complex_stack}->[1] );
}

# data connection established
sub handler_complex_connected {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  $heap->{data_rw_wheel} = POE::Wheel::ReadWrite->new(
    Handle     => $socket,
    InputEvent => 'data_input',
    ErrorEvent => 'data_error'
  );
    
  send_event( $heap->{complex_stack}->[0] . "_connected",
	      $heap->{complex_stack}->[1] );

  command( $heap->{complex_stack} );
} 

# data connection could not be established
sub handler_complex_connect_error {
  my ($kernel, $heap, $error) = @_[KERNEL, HEAP, ARG0];
  send_event( $heap->{complex_stack}->[0] . "_error", $error,
	      $heap->{complex_stack}->[1] );

  delete $heap->{data_sock_wheel};
  delete $heap->{data_rw_wheel};
  goto_state("ready");
}

# getting actual data, so send it to the client
sub handler_complex_list_data {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  warn ">> $input" if DEBUG;

  send_event( $heap->{complex_stack}->[0] . "_data", $input,
	      $heap->{complex_stack}->[1] );
}

# connection was closed, clean up
sub handler_complex_list_error {
  my ($kernel, $heap, $input) = @_[KERNEL, HEAP, ARG0];
  warn "error: complex_list: $input" if DEBUG;

  send_event( $heap->{complex_stack}->[0] . "_done",
	      $heap->{complex_stack}->[1] );

  delete $heap->{data_sock_wheel};
  delete $heap->{data_rw_wheel};
  goto_state("ready");
}

## utility functions

# maps all signal names to dispatcher
sub map_all {
  my $map = shift;
  my $coderef = shift;

  my %signals;
  foreach my $state (keys %$map) {
    @signals{ keys %{ $map->{$state} } } = ();
  }
  map { $_ = $coderef } values %signals;

  return \%signals;
}

# enqueues and incoming signal
sub enqueue_event { 
  my ($kernel, $heap, $state) = @_[KERNEL, HEAP, STATE];
  warn "|| enqueue $state" if DEBUG;

  push @{$heap->{queue}}, [ @_ ];
  
}

# dequeue and dispatch next event
# in a more general model, this could dequeue the first event
# that active session knows how to deal with
sub dequeue_event { 
  my $heap = $poe_kernel->get_active_session()->get_heap();
  return unless @{$heap->{queue}};

  my $state = $heap->{queue}->[0]->[STATE];

  dispatch( @{ shift @{$heap->{queue}} } );
}

# if active session knows how to handle this event, dispatch it to them
# if not, enqueue the event
sub dispatch {
  my ($kernel, $heap, $state) = @_[KERNEL, HEAP, STATE];

  my $coderef = ( $state_map->{ $heap->{state} }->{$state} || 
		  $state_map->{global}->{$state} ||
		  \&enqueue_event );


  warn "-> $heap->{state}\::$state" if DEBUG;
  &{ $coderef }(@_);
}

# Send events to interested sessions
sub send_event {
    my ( $event, @args ) = @_;
    warn "<*> $event" if DEBUG;

    my $heap = $poe_kernel->get_active_session()->get_heap();

    for my $session ( keys %{$heap->{events}} ) {
        if (
            exists $heap->{events}{$session}{$event} or
            exists $heap->{events}{$session}{all}
        )
        {
            $poe_kernel->post(
                $session,
                ( $heap->{events}{$session}{$event} || $event ),
                @args
            );
        }
    }
}

# run a command and add its call information to the call stack
sub command {
    my ($cmd_args, $state) = @_;

    $cmd_args = ref($cmd_args) eq "ARRAY" ? [ @$cmd_args ] : $cmd_args;

    my $heap = $poe_kernel->get_active_session()->get_heap();
    return unless defined $heap->{cmd_rw_wheel};
    
    $cmd_args = [$cmd_args] unless ref( $cmd_args ) eq 'ARRAY';
    my $command = uc shift( @$cmd_args );
    $state = {} unless defined $state;
    
    unshift @{$heap->{stack}}, [ $command, @$cmd_args ];
 
    $command = $command_map{$command} || $command;
    my $cmdstr = join( ' ', $command, @$cmd_args ? @$cmd_args : () );

    warn "> $cmdstr" if DEBUG;
    $heap->{cmd_rw_wheel}->put($cmdstr);
}

# change active state
sub goto_state {
  my $state = shift;
  warn "--> $state" if DEBUG;

  my $heap = $poe_kernel->get_active_session()->get_heap();
  $heap->{state} = $state;

  my $coderef = $state_map->{$state}->{_start};
  &{$coderef} if $coderef;

}

1;

__END__

=head1 NAME

POE::Component::Client::FTP - Implements an FTP client POE Component

=head1 SYNOPSIS

 use POE::Component::Client::FTP;

 POE::Component::Client::FTP->spawn (
   Alias      => 'ftp',
   Username   => 'test',
   Password   => 'test',
   RemoteAddr => 'localhost',
   Events     => [ qw( authenticated put_ready put_error put_closed
                       get_begin get_data get_done size ) ]
 );

 # we are authenticated
 sub authenticated {
   $poe_kernel->post('ftp', 'command', 'args');
 }

 # data connection is ready for data
 sub put_ready {
   my ($status, $line, $param) = @_[ARG0..ARG3];

   open FILE, "/etc/passwd" or die $!;
   $poe_kernel->post('ftp', 'put_data', $_) while (<FILE>);
   close FILE;
   $poe_kernel->post('ftp', 'put_close');
 }

 # something bad happened
 sub put_error {
   my ($error, $param) = @_[ARG0,ARG1];

   warn "ERROR: '$error' occured while trying to STOR '$param'";
 }

 # data connection closed
 sub put_closed {
   my ($param) = @_[ARG0];
 }

 # file on the way...
 sub get_begin {
   my ($filename) = @_[ARG0];
 }

 # getting data from the file...
 sub get_data {
   my ($data, $filename) = @_[ARG0,ARG1];

 }

 # and its done 
 sub get_done {
   my ($filename) = @_[ARG0];
 } 

 # response to a size command
 sub size {
   my ($code, $size, $filename) = @_[ARG0,ARG1,ARG2];
  
   print "$filename was $size";
 }

 $poe_kernel->run();

Latest version and samples script can be found at:
L<http://www.wush.net/poe/ftp>

=head1 DESCRIPTION

Client module for FTP

=head1 CAVEATS

Untested.

=head1 METHODS

=item spawn

=over

=item Alias      - session name

=item Username   - account username

=item Password   - account password

=item LocalAddr  - unused

=item LocalPort  - unused

=item RemoteAddr - ftp server

=item RemotePort - ftp port

=item Timeout    - unused

=item Blocksize  - unused

=item Events     - events you are interested in receiving.  See OUTPUT.

=back

=head1 INPUT

=over

=item cd [path]

=item cdup

=item delete [filename]

=item dir

=item get [filename]

=item ls

=item mdtm [filename]

=item mkdir [dir name]

=item mode [active passive]

=item noop

=item pwd

=item rmdir [dir name]

=item site [command]

=item size [filename]

=item type [ascii binary]

=item quit

=item put_data

After receiving a put_ready event you can post put_data events to send data to
the server.

=item put_close

Closes the data connection.  put_closed will be emit when connection is flushed
and closed.

=back

=head1 OUTPUT

Output is for "simple" ftp events is simply "event".  Error cases are 
"event_error".  ARG0 is the numeric code, ARG1 is the text response,
and ARG2 is the parameter you made the call with.  This is useful since
commands such as size do not remind you of this in the server response.

Output for "complex" or data socket ftp commands is creates "event_begin"
upon socket connection, "event_data" for each item of data, and "event_done"
when all data is done being sent.

Output from put is "put_error" for an error creating a connection or
"put_ready".  If you receive "put_ready" you can post "put_data" commands
to the component to have it write.  A "put_done" command closes and writes.
Upon completion, a "put_closed" or "put_error" is posted back to you.

=head1 SEE ALSO

the POE manpage, the perl manpage, the Net::FTP module, RFC 959

=head1 BUGS

=item Active mode not supported

=item Error checking assumes a closed socket is normal.  No way around this.

=item Lack of documentation

=head1 AUTHORS & COPYRIGHT

Copyright (c) 2002 Michael Ching. All rights reserved. This program is free 
software; you can redistribute it and/or modify it under the same terms as 
Perl itself. 
