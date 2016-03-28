use strict;
use warnings;
use Promise;
use POP3Server;
use AnyEvent::Socket;

my $host = '127.0.0.1';
my $port = 4223;

tcp_server $host, $port, sub {
  my ($fh, $remote_host, $remote_port) = @_;
  warn "Remote: $remote_host:$remote_port";

  my $server = POP3Server->new;
  $server->set_fh ($fh);
};

Promise->new (sub { })->to_cv->recv;
