use POE;
use POE::Component::Client::FTP;
$|++;

POE::Session->create
    (
     inline_states => {
		       "_start"    => \&start,
		       "authenticated" => \&authenticated,
		       put_ready => \&put_ready,
		       put_closed => \&put_closed,
		       put_flushed => \&put_flushed,
		       put_error => \&put_error
		      }     
    );

sub start {
    my $ftp = POE::Component::Client::FTP->spawn
    (
     Alias      => 'ftp',
     
     RemoteAddr => '',
     Username   => '',
     Password   => '',

     Events => [qw(all)]
    );
}

sub authenticated {
    $poe_kernel->post('ftp', 'type', 'I');
    $poe_kernel->post('ftp', 'put', 'test.ftp');
}

sub put_ready {
  my ($heap) = @_[HEAP];

  open FILE, "$ENV{HOME}/public_html/test.act" or die $!;
  my $buf;
  while (read FILE, $buf, 10240) {
    $heap->{bs} += length $buf;
    print ".";
    $poe_kernel->post('ftp', 'put_data', $buf) 
  }
  close FILE;
  $poe_kernel->post('ftp', 'put_close');
}

sub put_flushed {
  my ($heap, $bytes) = @_[HEAP, ARG0];
  $heap->{br} += $bytes;

  print "!" x ($bytes / 1024);
}

sub put_error {
  die;
}

sub put_closed {
  my ($heap) = @_[HEAP];

  print join "\n", "X", $heap->{bs}, $heap->{br}, $heap->{bs} - $heap->{br};
  $poe_kernel->post('ftp', 'quit');
}

$poe_kernel->run();
